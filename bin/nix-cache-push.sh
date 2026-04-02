set -euo pipefail

fallback_nix="@fallbackNix@"
nix_cmd="$(command -v nix 2>/dev/null || true)"
if [ -z "$nix_cmd" ]; then
	nix_cmd="$fallback_nix"
fi

config_dir="${XDG_CONFIG_HOME:-$HOME/.config}/nix-cache-push"
config_path="$config_dir/config.json"
multipart_chunk_size=33554432
multipart_threshold=67108864

die() {
	echo "nix-cache-push: $*" >&2
	exit 1
}

usage() {
	cat <<'EOF'
Usage:
  nix-cache-push config show
  nix-cache-push config get KEY
  nix-cache-push config set KEY VALUE
  nix-cache-push INSTALLABLE [INSTALLABLE...]
  nix-cache-push STORE_PATH [STORE_PATH...]
  command-producing-store-paths | nix-cache-push

Config keys:
  endpoint
  bucket
  region
  accessKeyId
  signingKeyPath
  secretKeyPath

Examples:
  nix-cache-push config set endpoint nix-cache.sped0n.com
  nix-cache-push config set bucket nix-cache
  nix-cache-push config set accessKeyId writer
  nix-cache-push config show
  nix build .#hello --no-link --print-out-paths | nix-cache-push
  nix-cache-push .#hello nixpkgs#jq
  nix-cache-push /nix/store/...-hello-2.12.1

Notes:
  - Installables are built with `nix build --no-link --print-out-paths`.
  - Store paths are signed recursively before upload.
  - Uploaded NARs use zstd compression.
  - Secrets are loaded from file paths in ~/.config/nix-cache-push/config.json.
EOF
}

config_usage() {
	cat <<'EOF'
Usage:
  nix-cache-push config show
  nix-cache-push config get KEY
  nix-cache-push config set KEY VALUE

Config keys:
  endpoint
  bucket
  region
  accessKeyId
  signingKeyPath
  secretKeyPath
EOF
}

is_allowed_config_key() {
	case "$1" in
	endpoint | bucket | region | accessKeyId | signingKeyPath | secretKeyPath)
		return 0
		;;
	*)
		return 1
		;;
	esac
}

print_config_path() {
	printf 'Config path: %s\n' "$config_path"
}

ensure_config_dir() {
	mkdir -p "$config_dir"
}

ensure_valid_config_file() {
	if [ ! -f "$config_path" ]; then
		die "config file not found at $config_path. Use \`nix-cache-push config set <key> <value>\` to create it."
	fi

	if ! jq empty "$config_path" >/dev/null 2>&1; then
		die "invalid config JSON at $config_path"
	fi
}

require_config_key() {
	local key="$1"

	if ! jq -er --arg key "$key" '.[$key] | strings | select(length > 0)' "$config_path" >/dev/null; then
		die "missing required config key '$key' in $config_path"
	fi
}

expand_config_path() {
	local value="$1"
	local original="$1"
	local match var prefix suffix replacement
	local command_match command_output

	while [[ "$value" =~ \$\(([^()]*)\) ]]; do
		command_match="${BASH_REMATCH[0]}"

		if ! command_output="$(eval "${BASH_REMATCH[1]}")"; then
			die "config path '$original' command substitution failed: ${BASH_REMATCH[1]}"
		fi

		prefix="${value%%"$command_match"*}"
		suffix="${value#*"$command_match"}"
		value="${prefix}${command_output}${suffix}"
	done

	while [[ "$value" =~ (\$\{([A-Za-z_][A-Za-z0-9_]*)\}|\$([A-Za-z_][A-Za-z0-9_]*)) ]]; do
		match="${BASH_REMATCH[1]}"
		var="${BASH_REMATCH[2]:-${BASH_REMATCH[3]}}"

		if [ -z "${!var+x}" ]; then
			die "config path '$original' references unset environment variable '$var'"
		fi

		prefix="${value%%"$match"*}"
		suffix="${value#*"$match"}"
		replacement="${!var}"
		value="${prefix}${replacement}${suffix}"
	done

	printf '%s\n' "$value"
}

config_show() {
	print_config_path
	ensure_valid_config_file
	jq '.' "$config_path"
}

config_get() {
	local key="$1"

	if ! is_allowed_config_key "$key"; then
		die "unsupported config key '$key'"
	fi

	ensure_valid_config_file

	if ! jq -er --arg key "$key" '.[$key] | strings | select(length > 0)' "$config_path"; then
		die "config key '$key' is not set in $config_path"
	fi
}

config_set() {
	local key="$1"
	local value="$2"
	local current='{}'
	local tmp

	if ! is_allowed_config_key "$key"; then
		die "unsupported config key '$key'"
	fi

	ensure_config_dir

	if [ -f "$config_path" ]; then
		ensure_valid_config_file
		current="$(jq -c '.' "$config_path")"
	fi

	tmp="$(mktemp "$config_dir/config.json.XXXXXX")"

	printf '%s\n' "$current" |
		jq --arg key "$key" --arg value "$value" '. + {($key): $value}' >"$tmp"

	mv "$tmp" "$config_path"
	echo "Updated $key in $config_path"
}

handle_config_command() {
	local subcommand="${1:-}"

	case "$subcommand" in
	show)
		if [ "$#" -ne 1 ]; then
			config_usage >&2
			exit 2
		fi
		config_show
		;;
	get)
		if [ "$#" -ne 2 ]; then
			config_usage >&2
			exit 2
		fi
		config_get "$2"
		;;
	set)
		if [ "$#" -ne 3 ]; then
			config_usage >&2
			exit 2
		fi
		config_set "$2" "$3"
		;;
	-h | --help | "")
		config_usage
		if [ -z "$subcommand" ]; then
			exit 2
		fi
		;;
	*)
		die "unknown config subcommand '$subcommand'"
		;;
	esac
}

load_push_config() {
	ensure_valid_config_file

	require_config_key endpoint
	require_config_key bucket
	require_config_key region
	require_config_key accessKeyId
	require_config_key signingKeyPath
	require_config_key secretKeyPath

	endpoint="$(jq -r '.endpoint' "$config_path")"
	bucket="$(jq -r '.bucket' "$config_path")"
	region="$(jq -r '.region' "$config_path")"
	access_key_id="$(jq -r '.accessKeyId' "$config_path")"
	signing_key_path="$(expand_config_path "$(jq -r '.signingKeyPath' "$config_path")")"
	secret_key_path="$(expand_config_path "$(jq -r '.secretKeyPath' "$config_path")")"

	if [ ! -r "$signing_key_path" ]; then
		die "signing key file is not readable: $signing_key_path"
	fi

	if [ ! -r "$secret_key_path" ]; then
		die "secret access key file is not readable: $secret_key_path"
	fi

	cache_store="s3://${bucket}?scheme=https&endpoint=${endpoint}&region=${region}&addressing-style=path&multipart-upload=true&multipart-chunk-size=${multipart_chunk_size}&multipart-threshold=${multipart_threshold}&compression=zstd"
}

if [ "${1:-}" = "--help" ] || [ "${1:-}" = "-h" ]; then
	usage
	exit 0
fi

if [ "${1:-}" = "config" ]; then
	shift
	handle_config_command "$@"
	exit 0
fi

inputs=()
if [ "$#" -gt 0 ]; then
	inputs=("$@")
elif [ ! -t 0 ]; then
	while IFS= read -r line; do
		if [ -n "$line" ]; then
			inputs+=("$line")
		fi
	done
else
	usage >&2
	exit 2
fi

load_push_config

export AWS_ACCESS_KEY_ID="$access_key_id"
aws_secret_access_key="$(tr -d '\r\n' <"$secret_key_path")"
export AWS_SECRET_ACCESS_KEY="$aws_secret_access_key"
export AWS_DEFAULT_REGION="$region"
export AWS_REGION="$region"
export AWS_EC2_METADATA_DISABLED=true

declare -A seen_paths=()
store_paths=()

add_store_path() {
	local path="$1"

	if [ -z "$path" ]; then
		return
	fi

	if [ -n "${seen_paths[$path]:-}" ]; then
		return
	fi

	seen_paths[$path]=1
	store_paths+=("$path")
}

for input in "${inputs[@]}"; do
	if [[ "$input" == /nix/store/* ]]; then
		add_store_path "$input"
		continue
	fi

	while IFS= read -r path; do
		add_store_path "$path"
	done < <("$nix_cmd" build --no-link --print-out-paths "$input")
done

if [ "${#store_paths[@]}" -eq 0 ]; then
	die "no store paths resolved"
fi

"$nix_cmd" store sign --recursive --key-file "$signing_key_path" "${store_paths[@]}"
"$nix_cmd" copy --to "$cache_store" "${store_paths[@]}"

echo "Signed paths uploaded" >&2
printf '%s\n' "${store_paths[@]}"
