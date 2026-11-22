FROM python:3.13-slim

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1

WORKDIR /app
COPY app/requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt \
    && install -d -o 10001 -g 10001 /data /data/sqlite
COPY app/app.py .

USER 10001:10001
EXPOSE 8000
CMD ["python", "app.py"]
