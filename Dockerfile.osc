ARG GO_IMAGE=golang:1.24-alpine
ARG RUNTIME_IMAGE=alpine:3.21

FROM ${GO_IMAGE} AS go-stage
RUN apk add --no-cache bash git curl jq

FROM ${RUNTIME_IMAGE}
# CVE-2026-111497 (Node Brotli decoder): require patched nodejs and brotli-libs, fail the build otherwise
RUN apk add --no-cache bash git curl jq "nodejs>=22.23.4-r0" "brotli-libs>=1.1.1-r0" npm \
    && node -e 'const p=s=>(s||"0.0.0").split(".").map(Number),[M,m,q]=p(process.versions.node),[a,b,c]=p(process.versions.brotli),nodeOk=M===22&&(m>23||(m===23&&q>=4)),brOk=a>1||(a===1&&(b>=3||((b===1||b===2)&&c>=1)));if(!nodeOk||!brOk){console.error("node "+process.versions.node+" brotli "+process.versions.brotli+" is below 22.23.4 / 1.1.1 (CVE-2026-111497)");process.exit(1)}' \
    && node --version
COPY --from=go-stage /usr/local/go /usr/local/go
ENV PATH="/usr/local/go/bin:${PATH}"
COPY scripts/loading-server.js scripts/loading-page.html scripts/error-page.html /runner/
WORKDIR /runner
COPY scripts/docker-entrypoint.sh ./
RUN chmod +x /runner/docker-entrypoint.sh
VOLUME /usercontent
ENV PORT=8080
ENV CGO_ENABLED=0
EXPOSE 8080
ENTRYPOINT ["/runner/docker-entrypoint.sh"]
