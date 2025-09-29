# Use Python base image
FROM python:3.10-slim

# Install curl for healthchecks, etc.
RUN apt-get update \
 && apt-get install -y --no-install-recommends curl ca-certificates \
 && rm -rf /var/lib/apt/lists/*
# Set working directory
WORKDIR /app

# Copy application code to the container
COPY main.py requirements.txt /app/
COPY ./app /app/app/

# Install dependencies
RUN pip install --no-cache-dir -r requirements.txt

# Expose the application port
EXPOSE 5000

# Run the Flask app
CMD ["python", "main.py"]
