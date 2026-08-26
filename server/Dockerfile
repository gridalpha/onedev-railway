# OneDev server, prepared for Railway.
#
# The published image already reads every setting we need from environment
# variables (see `ServerConfig` / `HibernateConfig` upstream), so the only thing
# this layer adds is a boot-time pass that closes account self sign-up and
# registers a CI/CD job executor through OneDev's own REST API — neither is
# expressible as an environment variable, and both must be true before a
# template deployment is handed to the internet.
FROM 1dev/server:latest

USER root

RUN apt-get update \
 && apt-get install -y --no-install-recommends jq \
 && rm -rf /var/lib/apt/lists/*

# The image's CMD is ["/root/bin/entrypoint.sh"]. Shim that launcher rather than
# declaring an ENTRYPOINT of our own, which would empty the inherited CMD.
RUN mv /root/bin/entrypoint.sh /root/bin/entrypoint-upstream.sh

COPY entrypoint.sh /root/bin/entrypoint.sh
COPY job-executors.json /root/bin/job-executors.json

RUN chmod +x /root/bin/entrypoint.sh \
 && bash -n /root/bin/entrypoint.sh \
 && jq empty /root/bin/job-executors.json

EXPOSE 6610
EXPOSE 6611
