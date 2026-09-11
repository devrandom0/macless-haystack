FROM python:3.12-slim

ENV TERM=xterm
WORKDIR /app

COPY requirements.txt endpoint/requirements.txt
RUN pip install --no-cache-dir --upgrade pip \
    && pip install --no-cache-dir -r endpoint/requirements.txt

COPY . endpoint

RUN useradd --create-home --shell /usr/sbin/nologin appuser \
    && chown -R appuser:appuser /app
USER appuser

CMD ["python", "-u", "endpoint/mh_endpoint.py"]
