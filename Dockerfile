FROM alpine:3.19 AS builder

RUN apk add --no-cache git make gcc musl-dev linux-headers bash

WORKDIR /build
RUN git clone --depth=1 --branch v1.0.20260223 \
    https://github.com/amnezia-vpn/amneziawg-tools.git .

RUN make -C src -j$(nproc) && \
    make -C src install DESTDIR=/install PREFIX=/usr && \
    mkdir -p /install/usr/bin && \
    cp src/wg-quick/linux.bash /install/usr/bin/awg-quick && \
    chmod +x /install/usr/bin/awg-quick

FROM alpine:3.19

RUN apk add --no-cache \
    bash \
    iproute2 \
    iptables \
    ip6tables \
    openresolv \
    procps

COPY --from=builder /install/usr/bin/awg /usr/bin/awg
COPY --from=builder /install/usr/bin/awg-quick /usr/bin/awg-quick

VOLUME ["/etc/amnezia/amneziawg"]

ENTRYPOINT ["/bin/bash"]
