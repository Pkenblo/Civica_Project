import json
import unittest
from decimal import Decimal
from unittest.mock import patch

from visualizacion import panel


class Cursor:
    def __init__(self, mismatch=False, duplicate=False):
        self.mismatch, self.duplicate = mismatch, duplicate
        self.description = []
        self.calls = []

    def execute(self, sql, args=None):
        self.calls.append((sql, args))
        assert 'DEV_GOLD.MARTS.MART_ARREST_SOCIOECONOMIC' in sql
        if 'SELECT DISTINCT year' in sql:
            self.rows = [(2024,), (2025,), (2026,)]
        elif 'WITH contexto' in sql:
            assert args is None and 'DEV_GOLD.GOLD.dim_postal_codes' in sql
            self.description = [('CP',), ('GEOMETRY',), ('POPULATION',)]
            self.rows = [('98101', json.dumps({'type': 'Polygon', 'coordinates': []}), Decimal(100)),
                         ('98102', None, None)]
            if self.duplicate:
                self.rows.append(self.rows[0])
        elif 'AS has_point' in sql:
            assert args is None
            self.description = [('CP',), ('YEAR',), ('HAS_POSTAL_REFERENCE',), ('HAS_POINT',), ('ARREST_COUNT',)]
            self.rows = [('98101', 2024, True, True, Decimal(2)), (None, 2024, False, True, Decimal(1)),
                         (None, 2024, False, False, Decimal(4)), ('98101', 2025, True, True, Decimal(1))]
        else:
            assert args == (2024,) and 'point_geography IS NOT NULL' in sql
            self.description = [('LATITUDE',), ('LONGITUDE',), ('CP',), ('ARREST_COUNT',)]
            self.rows = [(Decimal('47.60123'), Decimal('-122.32123'), '98101', Decimal(2)),
                         (Decimal('47.65123'), Decimal('-122.31123'), None, Decimal(9 if self.mismatch else 1))]

    def __iter__(self):
        return iter(self.rows)

    def cursor(self):
        return self

    def close(self):
        pass


class SocioTest(unittest.TestCase):
    def test_contexto_unico_precision_puntos_sin_cp_y_sin_parametros_inventados(self):
        cursor = Cursor()
        with patch.object(panel, 'conectar', return_value=cursor):
            data = panel.socio('ultimo')
        self.assertEqual(data['anio'], 2024)
        self.assertEqual(len(data['zonas']), 2)
        self.assertEqual(data['zonas'][0]['population'], 100)
        self.assertIsNone(data['zonas'][1]['geometry'])
        self.assertIsNone(data['puntos'][1]['cp'])
        self.assertEqual(data['puntos'][0]['latitude'], 47.60123)
        self.assertEqual([args for _, args in cursor.calls[1:]], [None, None, (2024,)])
        json.dumps(data, allow_nan=False)

    def test_anio_inexistente(self):
        with patch.object(panel, 'conectar', return_value=Cursor()):
            data = panel.socio('2020')
        self.assertIsNone(data['anio'])
        self.assertEqual(data['puntos'], [])

    def test_reconciliacion_puntos(self):
        with patch.object(panel, 'conectar', return_value=Cursor(mismatch=True)):
            with self.assertRaises(ValueError):
                panel.socio('2024')

    def test_duplicados_en_catalogo(self):
        with patch.object(panel, 'conectar', return_value=Cursor(duplicate=True)):
            with self.assertRaises(ValueError):
                panel.socio('2024')
