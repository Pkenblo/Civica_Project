import json
import unittest
from decimal import Decimal
from unittest.mock import patch

from visualizacion import panel


class Cursor:
    calls = None

    def __init__(self):
        self.calls = []

    def execute(self, sql, args=None):
        self.calls.append((sql,args))
        assert 'DEV_GOLD.MARTS.MART_CRIMES_SOCIOECONOMIC' in sql
        if args:
            assert args == ('2024-01-01','2024-01-01')
            self.rows = [(Decimal('47.60123'),Decimal('-122.32123'),'Drogas','35A','DRUGS',2,None,'100 BLOCK',None)]
        elif 'AS crime_count' in sql:
            assert args is None
            self.description = [('CP',),('YEAR',),('HAS_POSTAL_REFERENCE',),('NIBRS_CATEGORY',),('NIBRS_CODE',),('NIBRS_DESCRIPTION',),('CRIME_COUNT',)]
            self.rows = [('98101',2024,True,'Drogas','35A','DRUGS',Decimal(2)),
                         (None,2025,False,'Sin clasificar',None,None,Decimal(1))]
        else:
            assert 'WHERE offense_date' not in sql  # El contexto no depende del mes o categoría.
            self.description = [('CP',),('GEOMETRY',),('MEDIAN_HOUSEHOLD_INCOME',),('INCOME_TOP_CODED',)]
            self.rows = [('98101',json.dumps({'type':'Polygon','coordinates':[]}),Decimal(50000),False),
                         ('98102',None,None,True)]

    def __iter__(self):
        return iter(self.rows)

    def cursor(self):
        return self

    def close(self):
        pass


class CrimePointsTest(unittest.TestCase):
    def test_nuevo_mart_contexto_unico_y_coordenadas_sin_cp(self):
        cursor = Cursor()
        with patch.object(panel,'conectar',return_value=cursor):
            data = panel.puntos('ultimo')
        self.assertEqual(data['mes'],'2024-01')
        self.assertEqual(data['filas'][0][:2],[47.60123,-122.32123])
        self.assertIsNone(data['filas'][0][6])
        self.assertEqual(data['zonas'][0]['median_household_income'],50000)
        self.assertIsNone(data['zonas'][1]['median_household_income'])
        self.assertTrue(data['zonas'][1]['income_top_coded'])
        self.assertEqual(len(cursor.calls),3)
        self.assertEqual(data['recuentos'][0]['crime_count'],2)
        self.assertEqual(data['recuentos'][1]['year'],2025)
        json.dumps(data,allow_nan=False)

    def test_fecha_fuera_del_periodo_no_conecta(self):
        with patch.object(panel,'conectar') as conn:
            with self.assertRaises(ValueError):
                panel.puntos('2023-12')
        conn.assert_not_called()
