FROM ubuntu:24.04

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        bats \
        build-essential \
        ca-certificates \
        curl \
        git \
        libssl-dev \
        pkg-config \
        python3 \
        vim \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/*

# Install Rust toolchain
RUN curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y --default-toolchain stable
ENV PATH="/root/.cargo/bin:${PATH}"

# Build qsv from a specific unreleased commit
# Update after the --split-ragged option is included in a release
ARG QSV_COMMIT=d0270f0933db0264bfdf0c35abe9e97a01abd3dc
RUN git clone https://github.com/dathere/qsv /tmp/qsv \
    && cd /tmp/qsv \
    && git checkout ${QSV_COMMIT} \
    && cargo build --release --locked --features feature_capable \
    && cp target/release/qsv /usr/local/bin/qsv \
    && rm -rf /tmp/qsv ~/.cargo/registry ~/.cargo/git

COPY . /xsv-validator/

# clone bats helpers
RUN git clone --depth 1 https://github.com/bats-core/bats-support /xsv-validator/tests/test_helper/bats-support \
    && git clone --depth 1 https://github.com/bats-core/bats-assert /xsv-validator/tests/test_helper/bats-assert \
    && git clone --depth 1 https://github.com/bats-core/bats-file /xsv-validator/tests/test_helper/bats-file

WORKDIR /xsv-validator
