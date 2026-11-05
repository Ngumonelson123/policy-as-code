# Minimal sample app used to demonstrate the pipeline.
# Runs as non-root by default so it passes the "restrict-privileged-workloads" policy.
FROM python:3.12-slim

RUN useradd --uid 1000 --create-home appuser
WORKDIR /app

COPY app.py .

USER 1000
EXPOSE 8000

CMD ["python", "app.py"]
