FROM ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update \
  && apt-get install -y --no-install-recommends \
    ca-certificates \
    curl \
    gnupg \
    python3 \
    python3-pip \
    python3-venv \
  && rm -rf /var/lib/apt/lists/*

# Install Node.js (LTS) from NodeSource
RUN curl -fsSL https://deb.nodesource.com/setup_lts.x | bash - \
  && apt-get update \
  && apt-get install -y --no-install-recommends nodejs \
  && rm -rf /var/lib/apt/lists/*

# Create a virtual environment and install OpenAI SDK into it
RUN python3 -m venv /opt/venv \
  && /opt/venv/bin/python -m ensurepip --upgrade \
  && /opt/venv/bin/pip install --upgrade pip \
  && /opt/venv/bin/pip install openai

ENV PATH="/opt/venv/bin:${PATH}"

WORKDIR /workspaces/rssss
