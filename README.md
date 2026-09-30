# golang-runner

A container runtime that enables deploying Go applications as My Apps on [Eyevinn Open Source Cloud](https://www.osaas.io/).

## What it does

golang-runner clones your Go repository, builds a static binary using `go build`, and runs it. It integrates with the OSC platform for config service support, build status signaling, and token-based authentication.

## Environment Variables

| Variable | Required | Description |
|---|---|---|
| `SOURCE_URL` | Yes (or `GITHUB_URL`) | HTTPS URL of the Git repository to clone. Append `#branchname` to specify a branch. |
| `GITHUB_URL` | Yes (or `SOURCE_URL`) | Alias for `SOURCE_URL` (backward compatibility). |
| `GIT_TOKEN` | No | Personal access token for private repositories. Injected into the clone URL. |
| `GITHUB_TOKEN` | No | Fallback for `GIT_TOKEN`. |
| `SUB_PATH` | No | Subdirectory within the cloned repo to use as the build root (monorepo support). |
| `PORT` | No | Port the Go server listens on. Default: `8080`. |
| `CGO_ENABLED` | No | Set to `1` to enable CGO. Default: `0` (produces static binaries). |
| `OSC_BUILD_CMD` | No | Override the auto-detected build command. Example: `go build -tags netgo -o /app/server ./cmd/api`. |
| `OSC_ENTRY` | No | Override the binary to execute after build. Default: `/app/server`. |
| `OSC_ACCESS_TOKEN` | No | OSC runner token for authenticating with the config service. |
| `CONFIG_API_KEY` | No | API key for encrypted parameter store. When set alongside `OSC_ACCESS_TOKEN` and `CONFIG_SVC`, secret parameters are decrypted before being injected as environment variables. |
| `CONFIG_SVC` | No | OSC config service endpoint for loading environment variables at startup. |

## Go Project Auto-Detection

When `OSC_BUILD_CMD` is not set, the entrypoint detects your project structure in this order:

1. `cmd/server/main.go` — builds `./cmd/server`
2. `cmd/*/main.go` — builds the first `cmd/` subdirectory found
3. `main.go` — builds `.` (root package)
4. Fallback: `go build ./...`

The compiled binary is always placed at `/app/server`.

## Example Usage

### Deploy a public Go server

```
SOURCE_URL=https://github.com/your-org/your-go-app
PORT=8080
```

### Deploy from a private repository

```
SOURCE_URL=https://github.com/your-org/private-go-app
GIT_TOKEN=ghp_yourtokenhere
```

### Deploy from a specific branch

```
SOURCE_URL=https://github.com/your-org/your-go-app#feat/new-api
```

### Monorepo with a subdirectory

```
SOURCE_URL=https://github.com/your-org/monorepo
SUB_PATH=services/my-service
```

### Custom build command

```
SOURCE_URL=https://github.com/your-org/your-go-app
OSC_BUILD_CMD=go build -tags netgo -ldflags="-extldflags=-static" -o /app/server ./cmd/api
```

### CGO enabled (requires gcc, adds to image size)

```
SOURCE_URL=https://github.com/your-org/your-go-app
CGO_ENABLED=1
OSC_BUILD_CMD=CGO_ENABLED=1 go build -o /app/server .
```

## Build Status Signaling

During the build phase, a loading server runs on `PORT` and responds to health checks:

- `GET /healthz` returns `503 Building` while the build is in progress
- `GET /healthz` returns `500 {"status":"build-failed"}` if the build fails
- All other requests return the loading page HTML

Once the build succeeds, the loading server is stopped and your Go binary takes over.

## OSC Config Service

If both `OSC_ACCESS_TOKEN` and `CONFIG_SVC` are set, the runner loads environment variables from the OSC config service before building. This allows secrets and runtime configuration to be managed through the OSC platform rather than being passed as container environment variables.

## Docker Images

The image is built on `alpine:3.21` and includes:
- Go toolchain copied from `golang:1.24-alpine`
- `bash`, `git`, `curl`, `jq`, `nodejs`, `npm`
- `CGO_ENABLED=0` by default for fully static binaries

For OSC catalog publishing, `Dockerfile.osc` is identical to `Dockerfile` and is the file used by the OSC maker build pipeline.
