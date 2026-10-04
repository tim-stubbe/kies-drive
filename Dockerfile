FROM python:3.13-slim
WORKDIR /app
COPY Server/requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
COPY Server/app ./app
VOLUME ["/data"]
EXPOSE 8080
CMD ["uvicorn", "app.main:app", "--host", "0.0.0.0", "--port", "8080"]
