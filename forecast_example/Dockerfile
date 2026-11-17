# Worked example image. Build from the repository root:
#   docker build --platform linux/amd64 -t forecast-example forecast_example
FROM python:3.12-slim

WORKDIR /app
COPY requirements.txt /app/requirements.txt
RUN pip install --no-cache-dir --requirement /app/requirements.txt
COPY forecast.py /app/forecast.py

# You run as an arbitrary UID with no passwd entry and no group membership:
# everything you ship must be world-readable, programs world-executable.
RUN chmod -R a+rX /app

# Exec form, and nothing the image does not contain. The platform adds its own
# init (docker --init), so you do not need tini.
ENTRYPOINT ["python", "/app/forecast.py"]
