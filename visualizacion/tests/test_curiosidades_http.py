import json
import threading
import unittest
import urllib.error
import urllib.request
from http.server import ThreadingHTTPServer
from unittest.mock import patch

from visualizacion import panel


class CuriousHTTPTest(unittest.TestCase):
    def setUp(self):
        self.server = ThreadingHTTPServer(('127.0.0.1', 0), panel.Panel)
        thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        thread.start()
        self.base = f'http://127.0.0.1:{self.server.server_port}'
        self.addCleanup(self.server.server_close)
        self.addCleanup(thread.join)
        self.addCleanup(self.server.shutdown)

    def request(self, path, headers=None):
        req = urllib.request.Request(self.base + path, data=b'', headers=headers or {'X-Civica': 'panel'})
        try:
            return urllib.request.urlopen(req)
        except urllib.error.HTTPError as error:
            return error

    def test_periodos_permitidos_y_fuera_de_rango(self):
        with patch.object(panel, 'curiosidades', return_value={'datos': {}, 'avisos': {}}) as query:
            for year in ['2024', '2025', '2026', 'todos']:
                with self.request('/curiosidades/' + year) as response:
                    self.assertEqual(response.status, 200)
                    self.assertEqual(json.load(response)['datos'], {})
            self.assertEqual(query.call_count, 4)
            with self.request('/curiosidades/2023') as response:
                self.assertEqual(response.status, 400)
            self.assertEqual(query.call_count, 4)

    def test_error_sin_exponer_conexion_y_peticion_sin_cabecera(self):
        with patch.object(panel, 'curiosidades', side_effect=RuntimeError('password privado')) as query:
            with self.request('/curiosidades/2024', headers={'Accept': 'application/json'}) as response:
                self.assertEqual(response.status, 403)
            query.assert_not_called()
            with self.request('/curiosidades/2024') as response:
                self.assertEqual(response.status, 503)
                self.assertNotIn('privado', response.read().decode())

    def test_script_y_estilos_locales(self):
        for path, content_type in [('/curiosidades.js', 'application/javascript'), ('/panel.css', 'text/css')]:
            with urllib.request.urlopen(self.base + path) as response:
                self.assertEqual(response.status, 200)
                self.assertIn(content_type, response.headers['Content-Type'])
                self.assertTrue(response.read())
