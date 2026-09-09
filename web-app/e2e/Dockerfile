# Keep this in lockstep with the resolved @playwright/test package version in
# web-app/package-lock.json. The image already contains the matching Chromium
# binary and its operating-system dependencies.
FROM mcr.microsoft.com/playwright:v1.57.0-noble@sha256:3bed4b1a12f2338642f3d8cba28e291deef3c66bd4a964bbeb3e57bbff511dbd

WORKDIR /work

COPY package.json package-lock.json ./
RUN npm ci

# The E2E suite reads mocks and document fixtures from the filesystem. They
# must live in the runner image because Testcontainers archives mocks from the
# Node process before copying them into WireMock.
COPY playwright.config.ts ./
COPY e2e ./e2e

ENV CI=true

ENTRYPOINT ["npm", "run", "test:e2e:mock"]
