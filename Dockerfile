# Define top-level build arguments
ARG VERSION=docker-dev
ARG COMMIT=unknown
ARG BUILD_DATE=unknown

# Stage 1: Install frontend dependencies
FROM docker.io/node:24-alpine@sha256:e67514e5d0f6c46656005e1b693b2ec9d52e80b641307de684d4a015ba7a4eaf AS frontend-deps

# Set the working directory inside the container
WORKDIR /app

# Install necessary packages
RUN apk add --no-cache git

# Copy package.json and package-lock.json
COPY web-app/package.json web-app/package-lock.json ./

# Install the dependency graph locked in package-lock.json
RUN npm ci

# Stage 1a: Run the frontend checks in an isolated build stage.
FROM frontend-deps AS frontend-test

# Copy the frontend code
COPY web-app /app/

RUN npm run lint && npm run build

# Stage 1b: Build Vite frontend
FROM frontend-deps AS frontend

# Copy the frontend code
COPY web-app /app/

# Build the frontend
RUN npm run build

# Stage 2: Build the Go binary
FROM docker.io/golang:1.25.5-alpine3.21@sha256:b4dbd292a0852331c89dfd64e84d16811f3e3aae4c73c13d026c4d200715aff6 AS builder

# Set the working directory inside the container
WORKDIR /app

# Package versions for Renovate
# renovate: datasource=repology depName=alpine_3_21/gcc versioning=loose
ENV GCC_VERSION="14.2.0-r4"
# renovate: datasource=repology depName=alpine_3_21/musl-dev versioning=loose
ENV MUSL_DEV_VERSION="1.2.5-r11"
# renovate: datasource=repology depName=alpine_3_21/mupdf versioning=loose
ENV MUPDF_VERSION="1.24.10-r0"
# renovate: datasource=repology depName=alpine_3_21/mupdf-dev versioning=loose
ENV MUPDF_DEV_VERSION="1.24.10-r0"
# renovate: datasource=repology depName=alpine_3_21/sed versioning=loose
ENV SED_VERSION="4.9-r2"

# Install necessary packages with pinned versions
RUN apk add --no-cache \
    "gcc=${GCC_VERSION}" \
    "musl-dev=${MUSL_DEV_VERSION}" \
    "mupdf=${MUPDF_VERSION}" \
    "mupdf-dev=${MUPDF_DEV_VERSION}" \
    "sed=${SED_VERSION}"

# Copy go.mod and go.sum files
COPY go.mod go.sum ./

# Download dependencies
RUN go mod download

# Pre-compile go-sqlite3 to avoid doing this every time
RUN CGO_ENABLED=1 go build -tags musl -o /dev/null github.com/mattn/go-sqlite3

# Copy the frontend build
COPY --from=frontend /app/dist /app/web-app/dist

# Copy the Go source files
COPY *.go .
COPY ocr ./ocr
COPY sanitize ./sanitize
COPY internal ./internal
COPY default_prompts ./default_prompts
COPY tests ./tests

# Stage 2a: Run backend formatting and tests in an isolated build stage.
# Keep parallelism deliberately bounded for CI runners and developer hosts.
FROM builder AS backend-test
RUN gofmt -l . | tee /tmp/gofmt.out && test ! -s /tmp/gofmt.out
RUN CGO_ENABLED=1 GOMAXPROCS=4 go test -tags musl ./...

# Continue the runtime build from the unmodified builder stage so test-only
# commands cannot affect the resulting production image.
FROM builder AS runtime-builder

# Import ARGs from top level
ARG VERSION
ARG COMMIT
ARG BUILD_DATE

# Update version information
RUN sed -i \
    -e "s/devVersion/${VERSION}/" \
    -e "s/devBuildDate/${BUILD_DATE}/" \
    -e "s/devCommit/${COMMIT}/" \
    version.go

# Build the binary using caching for both go modules and build cache
ARG GO_BUILD_PARALLELISM=4
RUN CGO_ENABLED=1 GOMAXPROCS=${GO_BUILD_PARALLELISM} go build -tags musl -o paperless-gpt .

# Stage 3: Create a lightweight image with just the binary
FROM docker.io/alpine:3.23.0@sha256:51183f2cfa6320055da30872f211093f9ff1d3cf06f39a0bdb212314c5dc7375

ENV GIN_MODE=release

# Install necessary runtime dependencies
RUN apk add --no-cache \
    ca-certificates \
    su-exec

# Set the working directory inside the container
WORKDIR /app/

# Copy the Go binary from the builder stage
COPY --from=runtime-builder /app/paperless-gpt .

# Copy the entrypoint script
COPY entrypoint.sh .
RUN chmod +x ./entrypoint.sh

# Copy the prompt templates
COPY default_prompts/ /app/default_prompts/

# Expose the port the app runs on
EXPOSE 8080

# Set the entrypoint
ENTRYPOINT ["./entrypoint.sh"]
