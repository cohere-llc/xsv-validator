FROM ubuntu:latest

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        gpg \
        wget \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/*

RUN wget -O /tmp/qsv-deb.gpg https://dathere.github.io/qsv-deb-releases/qsv-deb.gpg \
    && gpg --dearmor -o /usr/share/keyrings/qsv-deb.gpg /tmp/qsv-deb.gpg \
    && echo "deb [signed-by=/usr/share/keyrings/qsv-deb.gpg] https://dathere.github.io/qsv-deb-releases ./" | tee /etc/apt/sources.list.d/qsv.list

RUN apt -y update \
    && apt -y install \
        bats \
        git \
        qsv \
        vim \
    && apt clean all

COPY . /xsv-validator/

# clone bats helpers
RUN git clone https://github.com/bats-core/bats-support /xsv-validator/tests/test_helper/bats-support \
    && git clone https://github.com/bats-core/bats-assert /xsv-validator/tests/test_helper/bats-assert \
    && git clone https://github.com/bats-core/bats-file /xsv-validator/tests/test_helper/bats-file

WORKDIR /xsv-validator
