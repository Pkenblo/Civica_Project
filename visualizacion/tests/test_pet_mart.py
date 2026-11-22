import json
import unittest
from unittest.mock import patch

from visualizacion import panel


class PetMartTest(unittest.TestCase):
    def test_indicadores_y_licencias_se_leen_del_mismo_mart(self):
        row = ['comparacion','98101',2024,2,50,70,0,0,3,100,120,0,0,4]

        class Cursor:
            calls = []

            def execute(self, sql):
                self.calls.append(sql)

            def __iter__(self):
                return iter([(json.dumps(row),)])

            def cursor(self):
                return self

            def close(self):
                pass

        cursor = Cursor()
        with patch.object(panel, 'conectar', return_value=cursor):
            result = panel.consultar()
        self.assertEqual(result['rows'], [row])
        self.assertEqual(len(cursor.calls), 1)
        self.assertIn('DEV_GOLD.MARTS.MART_CRIMES_PET_LICENSES', cursor.calls[0])
        self.assertNotIn('DEV_GOLD.GOLD.', cursor.calls[0])
        for indicator in ('vehicle_theft_count','theft_count','shooting_or_homicide_count',
                          'dog_license_count','cat_license_count','cumulative_dog_license_count'):
            self.assertIn(indicator, cursor.calls[0])
