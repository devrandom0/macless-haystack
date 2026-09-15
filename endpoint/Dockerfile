FROM --platform=$BUILDPLATFORM ghcr.io/cirruslabs/flutter:stable AS webbuild
WORKDIR /src
COPY macless_haystack macless_haystack
WORKDIR /src/macless_haystack
RUN flutter pub get && flutter build web --base-href=/webapp/

FROM python:3.12-slim

ENV TERM=xterm
WORKDIR /app

COPY endpoint/requirements.txt endpoint/requirements.txt
RUN pip install --no-cache-dir --upgrade pip \
    && pip install --no-cache-dir -r endpoint/requirements.txt

COPY endpoint endpoint
COPY --from=webbuild /src/macless_haystack/build/web endpoint/web_dist

RUN useradd --create-home --shell /usr/sbin/nologin appuser \
    && chown -R appuser:appuser /app
USER appuser

CMD ["python", "-u", "endpoint/mh_endpoint.py"]
