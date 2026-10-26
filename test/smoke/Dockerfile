# A host for test/smoke/run.sh: the distro image with systemd as PID 1 (run --privileged), plus
# what a typical server has and the slim images lack: curl, CA certificates, sudo. The user
# "smoke" runs the one-liner through sudo, as a person would.
ARG BASE=debian:12
FROM ${BASE}
ENV container=docker DEBIAN_FRONTEND=noninteractive
RUN apt-get update \
 && apt-get install -y --no-install-recommends systemd systemd-sysv dbus curl ca-certificates sudo \
 && rm -rf /var/lib/apt/lists/* \
 && useradd --create-home --shell /bin/bash smoke \
 && echo 'smoke ALL=(ALL) NOPASSWD: ALL' >/etc/sudoers.d/smoke \
 && chmod 0440 /etc/sudoers.d/smoke \
 && systemctl mask getty.target console-getty.service systemd-firstboot.service
STOPSIGNAL SIGRTMIN+3
CMD ["/sbin/init"]
