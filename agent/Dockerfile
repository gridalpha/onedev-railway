# OneDev CI/CD agent, prepared for Railway.
#
# An agent authenticates to the server with a token row that only exists in the
# server's database, so the value cannot be carried by a Railway variable or by
# `${{secret(N)}}`. This layer adds an entrypoint that asks the server to mint
# one on first boot and keeps it on the agent's volume from then on.
FROM 1dev/agent:latest

USER root

RUN apt-get update \
 && apt-get install -y --no-install-recommends jq procps netcat-openbsd \
 && rm -rf /var/lib/apt/lists/*

RUN mv /root/bin/entrypoint.sh /root/bin/entrypoint-upstream.sh

COPY entrypoint.sh /root/bin/entrypoint.sh

RUN chmod +x /root/bin/entrypoint.sh \
 && bash -n /root/bin/entrypoint.sh
