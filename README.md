# nix-cache-push

Signs and pushes Nix store paths to S3-compatible binary caches.

## Run

```bash
nix run https://github.com/Sped0n/nix-cache-push -- --help
```

## Install

```bash
nix profile install https://github.com/Sped0n/nix-cache-push
```

## Config

The tool reads its runtime configuration from `~/.config/nix-cache-push/config.json`.

Supported commands:

```bash
nix-cache-push config show
nix-cache-push config get endpoint
nix-cache-push config set endpoint nix-cache.example.com
```

`config show` prints the resolved config path on the first line, then pretty-prints the JSON contents.

Example setup:

```bash
nix-cache-push config set endpoint nix-cache.sped0n.com
nix-cache-push config set bucket nix-cache
nix-cache-push config set region us-east-1
nix-cache-push config set accessKeyId writer
nix-cache-push config set signingKeyPath /run/secrets/nix-cache-signing-key
nix-cache-push config set secretKeyPath /run/secrets/nix-cache-secret-access-key
```

Expected config shape:

```json
{
  "endpoint": "nix-cache.sped0n.com",
  "bucket": "nix-cache",
  "region": "us-east-1",
  "accessKeyId": "writer",
  "signingKeyPath": "/run/secrets/nix-cache-signing-key",
  "secretKeyPath": "/run/secrets/nix-cache-secret-access-key"
}
```

The config stores file paths to secrets, not the secret contents.

## Usage

Build an installable and push the resulting store paths:

```bash
nix-cache-push .#hello nixpkgs#jq
```

Push an existing store path directly:

```bash
nix-cache-push /nix/store/...-hello-2.12.1
```

Pipe store paths from another command:

```bash
nix build .#hello --no-link --print-out-paths | nix-cache-push
```

## Notes

- Uploads use `zstd` compression.
- The tool preserves the current behavior of signing store paths recursively before upload.
- The current repository's Home Manager module is not required by this standalone flake.
