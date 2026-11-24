"""Panel local: una lectura de Gold por apertura de página."""

import hashlib
import getpass
import json
import os
import re
import sys
import tempfile
import webbrowser
from contextlib import closing
from datetime import datetime, timezone
from decimal import Decimal
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from threading import Lock


ROOT = Path(__file__).resolve().parent
PROFILE = os.getenv('SNOWFLAKE_CONNECTION_NAME', 'civica')
CACHE = ROOT / '.cache' / (hashlib.sha256(PROFILE.encode()).hexdigest() + '.json')
LOCK = Lock()
LOGIN = {}
VIEW_YEARS = (2024, 2025, 2026)
DEFAULT_YEAR = 2024


def preparar_login():
    # Usar la misma configuración que el conector, también si se cambia de perfil.
    try:
        from snowflake.connector.config_manager import CONFIG_MANAGER
        perfil = CONFIG_MANAGER['connections'].get(PROFILE, {})
    except Exception:
        return  # La carga normal seguirá disponiendo de la copia sin conexión.
    if (perfil and str(perfil.get('authenticator', 'snowflake')).lower() in
            ('snowflake', 'username_password_mfa') and not perfil.get('password')
            and not any(k in perfil for k in ('private_key', 'private_key_file', 'token'))
            and sys.stdin.isatty()):
        password = getpass.getpass(f'Contraseña de Snowflake para el perfil {PROFILE} (no se mostrará): ')
        if password:
            LOGIN['password'] = password


def conectar():
    import snowflake.connector

    opciones = dict(LOGIN)
    if '--codigo-mfa' in sys.argv and sys.stdin.isatty():
        opciones['passcode'] = getpass.getpass('Código actual de la aplicación de autenticación: ')
    return snowflake.connector.connect(
        connection_name=PROFILE, database='DEV_GOLD', schema='GOLD',
        login_timeout=15, network_timeout=45,
        session_parameters={'STATEMENT_TIMEOUT_IN_SECONDS': 120},
        **opciones,
    )


def consultar():
    with closing(conectar()) as conn, closing(conn.cursor()) as cur:
        cur.execute((ROOT / 'panel.sql').read_text())
        rows = [json.loads(raw) for raw, in cur]
    return {'date': datetime.now(timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ'), 'rows': rows,
            'aviso_homicidios': ''}


def guardar(datos):
    CACHE.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    with tempfile.NamedTemporaryFile(mode='w', dir=CACHE.parent, delete=False) as f:
        temporal = Path(f.name)
        try:
            json.dump(datos, f, separators=(',', ':'))
            f.flush()
            os.replace(temporal, CACHE)
        finally:
            temporal.unlink(missing_ok=True)


def puntos(mes):
    filas = []
    if mes == 'ultimo':
        mes = f'{DEFAULT_YEAR}-01'
    if int(mes[:4]) not in VIEW_YEARS:
        raise ValueError('Solo se admiten meses de 2024 a 2026')
    with closing(conectar()) as conn, closing(conn.cursor()) as cur:
        inicio = mes + '-01'
        cur.execute((ROOT / 'puntos.sql').read_text(), (inicio, inicio))
        for lat, lon, categoria, codigo, descripcion, n, cp, bloque, barrio in cur:
            filas.append([float(lat), float(lon), categoria, codigo, descripcion, int(n), cp, bloque, barrio])
        zonas = registros(cur, 'puntos_contexto.sql')
        for z in zonas:
            z['geometry'] = json.loads(z['geometry']) if z['geometry'] else None
        if len({z['cp'] for z in zonas}) != len(zonas):
            raise ValueError('El catálogo postal contiene CP duplicados')
        recuentos = registros(cur, 'puntos_anios.sql')
    return {'mes': mes, 'filas': filas, 'zonas': zonas, 'recuentos': recuentos,
            'fecha': datetime.now(timezone.utc).isoformat(timespec='seconds')}


def registros(cur, filename, args=None):
    cur.execute((ROOT / filename).read_text(), args)
    columnas = [c[0].lower() for c in cur.description]
    return [dict(zip(columnas, (float(v) if isinstance(v, Decimal) else v for v in r))) for r in cur]


def curiosidades(anio):
    """Seis agregados de Gold; un fallo de permisos no oculta los demás resultados."""
    if anio != 'todos' and anio not in {str(y) for y in VIEW_YEARS}:
        raise ValueError('Solo se admiten los años 2024, 2025 y 2026')
    inicio = f'{VIEW_YEARS[0] if anio == "todos" else anio}-01-01'
    fin = f'{VIEW_YEARS[-1] + 1 if anio == "todos" else int(anio) + 1}-01-01'
    datos, avisos = {}, {}
    with closing(conectar()) as conn, closing(conn.cursor()) as cur:
        for clave in ('nombres', 'horas', 'vehiculos', 'semana', 'tiroteos', 'agentes'):
            try:
                datos[clave] = registros(cur, f'curiosidades/{clave}.sql', (inicio, fin))
            except Exception as exc:
                print(f'Error en curiosidades/{clave}: {type(exc).__name__} ({getattr(exc, "errno", "—")})', flush=True)
                avisos[clave] = 'No se pudo consultar este dato. Revisa las fuentes y sus permisos SELECT en Gold.'
    return {'anio': anio, 'inicio': inicio, 'fin_exclusivo': fin, 'datos': datos, 'avisos': avisos,
            'fecha': datetime.now(timezone.utc).isoformat(timespec='seconds')}


def socio(anio):
    """Puntos exactos publicados, contexto único por CP y recuentos anuales de detenciones."""
    with closing(conectar()) as conn, closing(conn.cursor()) as cur:
        cur.execute('SELECT DISTINCT year FROM DEV_GOLD.MARTS.MART_ARREST_SOCIOECONOMIC '
                    'WHERE year BETWEEN 2024 AND 2026 ORDER BY year')
        anios = [int(r[0]) for r in cur if int(r[0]) in VIEW_YEARS]
        anio = DEFAULT_YEAR if anio == 'ultimo' else int(anio)
        if anio not in anios:
            return {'anio': None, 'anios': anios, 'zonas': [], 'puntos': [], 'recuentos': []}

        zonas = registros(cur, 'socio_contexto.sql')
        for z in zonas:
            z['geometry'] = json.loads(z['geometry']) if z['geometry'] else None
        recuentos = registros(cur, 'socio_anios.sql')
        puntos_arresto = registros(cur, 'socio.sql', (anio,))
        claves_zonas = {z['cp'] for z in zonas}
        if len(claves_zonas) != len(zonas):
            raise ValueError('El catálogo postal contiene CP duplicados')
        esperados = sum(r['arrest_count'] for r in recuentos if r['year'] == anio and r['has_point'])
        if sum(p['arrest_count'] for p in puntos_arresto) != esperados:
            raise ValueError('Los puntos y los recuentos no coinciden. Revisa la actualización del mart.')
    return {'anio': anio, 'anios': anios, 'zonas': zonas, 'puntos': puntos_arresto, 'recuentos': recuentos,
            'fecha': datetime.now(timezone.utc).isoformat(timespec='seconds')}


def cargar():
    try:
        datos = consultar()
    except Exception as exc:
        # No devolver mensajes de autenticación ni atributos de la conexión al navegador.
        print(f'Error de lectura: {type(exc).__name__} ({getattr(exc, "errno", "—")})', flush=True)
        aviso = (f'No se pudo cargar el panel. Comprueba el perfil «{PROFILE}», el warehouse, '
                 'los permisos y la publicación de DEV_GOLD.MARTS.MART_CRIMES_PET_LICENSES con sus columnas cumulative_*_license_count.')
        try:
            datos = json.loads(CACHE.read_bytes())
            if not (isinstance(datos['rows'], list) and isinstance(datos['date'], str)):
                raise ValueError('Formato incorrecto')
        except (OSError, ValueError, TypeError, KeyError):
            return 503, {'aviso': aviso + ' Aún no hay una copia local utilizable.'}
        return 200, {'datos': datos, 'aviso': aviso + ' Se muestra la última copia guardada.'}
    try:
        guardar(datos)
    except OSError:
        return 200, {'datos': datos, 'aviso': 'Lectura correcta, pero no se pudo guardar la copia local.'}
    return 200, {'datos': datos, 'aviso': ''}


class Panel(BaseHTTPRequestHandler):
    def local(self):
        return self.headers.get('Host') == f'127.0.0.1:{self.server.server_port}'

    def responder(self, code, tipo, body):
        self.send_response(code)
        self.send_header('Content-Type', tipo)
        self.send_header('Cache-Control', 'no-store')
        self.send_header('X-Frame-Options', 'DENY')
        self.send_header('Content-Length', str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        assets = {'/': ('index.html', 'text/html; charset=utf-8'),
                  '/index.html': ('index.html', 'text/html; charset=utf-8'),
                  '/panel.css': ('panel.css', 'text/css; charset=utf-8'),
                  '/mapa.js': ('mapa.js', 'application/javascript'),
                  '/delitos.js': ('delitos.js', 'application/javascript'),
                  '/socio.js': ('socio.js', 'application/javascript'),
                  '/curiosidades.js': ('curiosidades.js', 'application/javascript'),
                  '/correlaciones.html': ('correlaciones.html', 'text/html; charset=utf-8'),
                  '/marts-datos.js': ('marts-datos.js', 'application/javascript'),
                  '/leaflet/leaflet.js': ('leaflet/leaflet.js', 'application/javascript'),
                  '/leaflet/leaflet.css': ('leaflet/leaflet.css', 'text/css')}
        if not self.local() or self.path not in assets:
            return self.send_error(404)
        nombre, tipo = assets[self.path]
        self.responder(200, tipo, (ROOT / nombre).read_bytes())

    def do_POST(self):
        if not self.local() or self.headers.get('X-Civica') != 'panel':
            return self.send_error(403)
        with LOCK:
            mes = re.fullmatch(r'/puntos/(ultimo|[1-9][0-9]{3}-(?:0[1-9]|1[0-2]))', self.path)
            economico = re.fullmatch(r'/socio/(ultimo|[1-9][0-9]{3})', self.path)
            curiosos = re.fullmatch(r'/curiosidades/(todos|[1-9][0-9]{3})', self.path)
            if self.path == '/datos':
                code, payload = cargar()
            elif curiosos:
                if curiosos[1] != 'todos' and int(curiosos[1]) not in VIEW_YEARS:
                    return self.responder(400, 'application/json', b'{"aviso":"Solo se admiten 2024, 2025 y 2026."}')
                try:
                    code, payload = 200, curiosidades(curiosos[1])
                except Exception as exc:
                    print(f'Error de curiosidades: {type(exc).__name__} ({getattr(exc, "errno", "—")})', flush=True)
                    code, payload = 503, {'aviso': 'No se pudieron cargar los datos curiosos. Comprueba la conexión y los permisos de lectura en DEV_GOLD.GOLD.'}
            elif mes:
                if mes[1] != 'ultimo' and int(mes[1][:4]) not in VIEW_YEARS:
                    return self.responder(400, 'application/json', b'{"aviso":"Solo se admiten meses de 2024 a 2026."}')
                try:
                    code, payload = 200, puntos(mes[1])
                except Exception as exc:
                    print(f'Error al leer puntos: {type(exc).__name__} ({getattr(exc,"errno","—")})', flush=True)
                    code, payload = 503, {'aviso': 'No se pudo leer DEV_GOLD.MARTS.MART_CRIMES_SOCIOECONOMIC y su contexto. Comprueba su publicación y los permisos SELECT sobre el mart y DEV_GOLD.GOLD.DIM_POSTAL_CODES.'}
            elif economico:
                if economico[1] != 'ultimo' and int(economico[1]) not in VIEW_YEARS:
                    return self.responder(400, 'application/json', b'{"aviso":"Solo se admiten los anios 2024, 2025 y 2026."}')
                try:
                    code, payload = 200, socio(economico[1])
                except Exception as exc:
                    print(f'Error socioeconómico: {type(exc).__name__} ({getattr(exc,"errno","—")})', flush=True)
                    code, payload = 503, {'aviso': 'No se pudo cargar DEV_GOLD.MARTS.MART_ARREST_SOCIOECONOMIC. Comprueba su publicación y los permisos USAGE en MARTS, SELECT en el mart y SELECT en DEV_GOLD.GOLD.DIM_POSTAL_CODES. Si ya tienes acceso, revisa la coherencia de los puntos y recuentos.'}
            else:
                return self.send_error(404)
        self.responder(code, 'application/json', json.dumps(payload, separators=(',', ':')).encode())


if __name__ == '__main__':
    preparar_login()
    with ThreadingHTTPServer(('127.0.0.1', 0), Panel) as server:
        url = f'http://127.0.0.1:{server.server_port}/'
        print(f'Panel: {url}\nPerfil: {PROFILE} | DEV_GOLD.GOLD\nCtrl+C para cerrar.', flush=True)
        try:
            webbrowser.open_new_tab(url)
            server.serve_forever()
        except KeyboardInterrupt:
            pass
