FROM python:3.13-slim
WORKDIR /app
ARG TUNNEL_CLIENT_VERSION=v0.0.15
ARG TARGETARCH
RUN apt-get update \
    && apt-get install -y --no-install-recommends ca-certificates curl unzip \
    && curl -fsSL -o /tmp/tunnel-client.zip \
      "https://github.com/openai/tunnel-client/releases/download/${TUNNEL_CLIENT_VERSION}/tunnel-client-${TUNNEL_CLIENT_VERSION}-linux-${TARGETARCH}.zip" \
    && unzip -q /tmp/tunnel-client.zip -d /tmp/tunnel-client \
    && install -m 0755 /tmp/tunnel-client/tunnel-client /usr/local/bin/tunnel-client \
    && rm -rf /var/lib/apt/lists/* /tmp/tunnel-client /tmp/tunnel-client.zip
COPY Server/requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
COPY Server/app ./app
COPY Server/entrypoint.sh /usr/local/bin/kies-drive-entrypoint
VOLUME ["/data"]
EXPOSE 8080 18181
ENTRYPOINT ["/usr/local/bin/kies-drive-entrypoint"]
