FROM python:3.12-slim
RUN pip install --no-cache-dir "psycopg[binary]==3.2.*" requests==2.32.* numpy==2.* opencv-python-headless==4.10.*
COPY kategorien.py /app/kategorien.py
COPY relevanz.py /app/relevanz.py
CMD ["python", "-u", "/app/kategorien.py"]
