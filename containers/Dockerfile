FROM python:3.11-slim

WORKDIR /app

# Copy requirements.txt first for efficient layer caching
COPY requirements.txt .

# Install dependencies without caching to minimize image size
RUN pip install --no-cache-dir -r requirements.txt

# Copy application files
COPY model.py app.py ./

EXPOSE 8080

CMD ["uvicorn", "app:app", "--host", "0.0.0.0", "--port", "8080"]
