FROM ubuntu:24.04@sha256:2198e4c65076e9cb0b3d695219df667c0e3b0072da64ca3c2648aca17dcecaf5
ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update \
    && apt-get install -y --no-install-recommends sbcl python3 python3-venv ca-certificates tini \
    && rm -rf /var/lib/apt/lists/*
ENV PATH="/opt/bes-venv/bin:$PATH" \
    PYTHONDONTWRITEBYTECODE=1 PYTHONUNBUFFERED=1 OPENBLAS_NUM_THREADS=1 OMP_NUM_THREADS=1 MKL_NUM_THREADS=1 \
    XDG_CACHE_HOME="/opt/bes-cache" \
    CL_SOURCE_REGISTRY="(:source-registry (:directory \"/opt/bes/\") (:tree \"/opt/common-lisp/\") :ignore-inherited-configuration)"
COPY requirements.lock /opt/requirements.lock
RUN python3 -m venv /opt/bes-venv \
    && pip install --no-cache-dir -r /opt/requirements.lock
COPY CybORG/ /opt/official-cage2/
COPY bridge/ /opt/cage2-bridge/
COPY lisp/ /opt/common-lisp/
COPY bes/ /opt/bes/
COPY source-manifest.txt /opt/bes-source-manifest.txt
# CybORG's setup.py does not install its simulator source or Scenario2 data.
ENV PYTHONPATH="/opt/official-cage2:/opt/cage2-bridge/src"
WORKDIR /opt/bes
RUN printf '%s\n' '{"printPythonTraceback":true,"pycmd":"/opt/bes-venv/bin/python","numpyPickleLocation":"tmp","numpyPickleLowerBound":100000}' \
        > /opt/common-lisp/py4cl2-v2.9.3/.config \
    && sbcl --noinform --non-interactive --eval '(require :asdf)' --eval '(asdf:load-system :cl-tpg)' \
    && python -c 'import cardiff_env; import CybORG'
ENTRYPOINT ["/usr/bin/tini", "-g", "--", "python3", "/opt/bes/docker/meander.py"]
CMD ["smoke"]
