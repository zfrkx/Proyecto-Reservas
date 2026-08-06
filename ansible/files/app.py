from flask import Flask, jsonify, request
import psycopg2
from prometheus_client import Counter, Histogram, generate_latest, CONTENT_TYPE_LATEST
import time
import logging

logging.basicConfig(level=logging.INFO, format='%(asctime)s - %(levelname)s - %(message)s')

app = Flask(__name__)

REQUEST_COUNT = Counter('http_requests_total', 'Total peticiones', ['method', 'endpoint', 'http_status'])
REQUEST_LATENCY = Histogram('http_request_duration_seconds', 'Latencia', ['endpoint'])

DB_CONFIG = {
    "user": "admin_reservas",
    "password": "ClaveSegura123#",
    "host": "db-postgres",
    "port": "5432",
    "database": "reservas_db"
}

def get_db_connection():
    return psycopg2.connect(**DB_CONFIG)

def init_db():
    try:
        conn = get_db_connection()
        cur = conn.cursor()
        cur.execute('''
            CREATE TABLE IF NOT EXISTS recursos (
                id SERIAL PRIMARY KEY,
                nombre VARCHAR(100) NOT NULL,
                tipo VARCHAR(50) NOT NULL
            );
            CREATE TABLE IF NOT EXISTS reservas (
                id SERIAL PRIMARY KEY,
                recurso_id INTEGER REFERENCES recursos(id),
                usuario VARCHAR(100) NOT NULL,
                fecha DATE NOT NULL
            );
        ''')
        conn.commit()
        cur.close()
        conn.close()
        logging.info("Base de datos inicializada correctamente.")
    except Exception as e:
        logging.error(f"Error inicializando BD: {e}")

init_db()

@app.before_request
def before_request():
    request.start_time = time.time()

@app.after_request
def after_request(response):
    latency = time.time() - request.start_time
    REQUEST_LATENCY.labels(endpoint=request.path).observe(latency)
    REQUEST_COUNT.labels(method=request.method, endpoint=request.path, http_status=response.status_code).inc()
    return response

@app.route('/metrics')
def metrics():
    return generate_latest(), 200, {'Content-Type': CONTENT_TYPE_LATEST}

@app.route('/recursos', methods=['GET', 'POST'])
def gestionar_recursos():
    conn = get_db_connection()
    cur = conn.cursor()
    if request.method == 'POST':
        data = request.get_json()
        cur.execute("INSERT INTO recursos (nombre, tipo) VALUES (%s, %s) RETURNING id;", 
                    (data['nombre'], data['tipo']))
        nuevo_id = cur.fetchone()[0]
        conn.commit()
        cur.close()
        conn.close()
        return jsonify({"mensaje": "Recurso creado", "id": nuevo_id}), 201
    else:
        cur.execute("SELECT id, nombre, tipo FROM recursos;")
        recursos = [{"id": row[0], "nombre": row[1], "tipo": row[2]} for row in cur.fetchall()]
        cur.close()
        conn.close()
        return jsonify(recursos), 200

@app.route('/reservas', methods=['GET', 'POST'])
def gestionar_reservas():
    conn = get_db_connection()
    cur = conn.cursor()
    if request.method == 'POST':
        data = request.get_json()
        try:
            cur.execute("INSERT INTO reservas (recurso_id, usuario, fecha) VALUES (%s, %s, %s) RETURNING id;", 
                        (data['recurso_id'], data['usuario'], data['fecha']))
            nuevo_id = cur.fetchone()[0]
            conn.commit()
            status, response = 201, {"mensaje": "Reserva creada", "id": nuevo_id}
        except Exception as e:
            conn.rollback()
            status, response = 400, {"error": "Recurso no existe o datos inválidos"}
        cur.close()
        conn.close()
        return jsonify(response), status
    else:
        cur.execute('''
            SELECT r.id, rec.nombre, r.usuario, r.fecha 
            FROM reservas r 
            JOIN recursos rec ON r.recurso_id = rec.id;
        ''')
        reservas = [{"id": row[0], "recurso": row[1], "usuario": row[2], "fecha": str(row[3])} for row in cur.fetchall()]
        cur.close()
        conn.close()
        return jsonify(reservas), 200

if __name__ == '__main__':
    app.run(host='0.0.0.0', port=5000)
