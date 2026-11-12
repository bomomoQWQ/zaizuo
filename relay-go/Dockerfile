# Build from relay-go/: docker build -t zaizuo-relay:local .
FROM golang:1.27-alpine AS build
WORKDIR /src
COPY go.mod go.sum ./
RUN go mod download
COPY . .
RUN CGO_ENABLED=0 go build -trimpath -ldflags="-s -w" -o /out/relay ./cmd/relay

FROM scratch
COPY --from=build /out/relay /relay
USER 65532:65532
EXPOSE 8787
ENTRYPOINT ["/relay"]
# Preserve the program's loopback-only default. Container networking requires an
# explicit -listen override plus a loopback-published port or TLS reverse proxy.
