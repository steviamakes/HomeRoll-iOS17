FROM python:3.12-slim
RUN pip install --no-cache-dir onnxruntime==1.20.* numpy==2.* opencv-python-headless==4.10.* requests==2.32.* legacy-cgi
RUN mkdir /models && python -c "import urllib.request; urllib.request.urlretrieve('https://huggingface.co/Carve/LaMa-ONNX/resolve/main/lama_fp32.onnx', '/models/lama_fp32.onnx')"
COPY bereinigen.py /app/bereinigen.py
CMD ["python", "-u", "/app/bereinigen.py"]
