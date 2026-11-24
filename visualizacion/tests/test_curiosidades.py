"""Agregados sobre fixtures SQLite; adaptación explícita de fechas de Snowflake."""

import json
import sqlite3
import unittest
from decimal import Decimal
from unittest.mock import patch

from visualizacion import panel


class CuriousSQLTest(unittest.TestCase):
    def setUp(self):
        self.db = sqlite3.connect(':memory:')
        self.db.row_factory = sqlite3.Row
        self.addCleanup(self.db.close)
        self.db.executescript('''
            CREATE TABLE dim_licenses (license_number, species, animal_name, license_issue_date);
            INSERT INTO dim_licenses VALUES
              ('d1','DOG','LUNA','2024-01-01'), ('d2','DOG','LUNA','2024-01-02'),
              ('d3','DOG','MAX','2024-01-03'), ('d4','DOG','MAX','2024-01-04'),
              ('d5','DOG',' ','2024-01-05'), ('d6','DOG','LUNA',NULL),
              ('d7','DOG','OTRO','2023-12-31'), ('d8','DOG','OTRO','2025-01-01'),
              ('c1','CAT','MILO','2024-01-01'), ('c2','CAT','MILO','2024-01-02');
            CREATE TABLE fact_crimes (crime_id, report_id, nibrs_key, address_id, offense_date_time);
            INSERT INTO fact_crimes VALUES
              ('c1','r1','vehicle','a','2024-01-01 10:00:00'),
              ('c2','r1','vehicle','a','2024-01-02 10:15:00'),
              ('c3','r2','vehicle','b','2024-01-03 11:00:00'),
              ('c4',NULL,'vehicle','b','2024-01-04 11:30:00'),
              ('c5','r4','vehicle','redacted','2024-01-05 12:00:00'),
              ('c6','r5','vehicle','missing','2024-01-06 13:00:00'),
              ('old','r1','vehicle','a','2023-12-31 10:00:00'),
              ('undated','r1','vehicle','a',NULL);
            CREATE TABLE dim_nibrs (nibrs_key, offense_code);
            INSERT INTO dim_nibrs VALUES ('vehicle','240');
            CREATE TABLE dim_address (address_id, block_address, is_location_redacted);
            INSERT INTO dim_address VALUES ('a','100 BLOCK A ST',FALSE),
              ('b','200 BLOCK B ST',FALSE), ('redacted','SECRET',TRUE);
            CREATE TABLE fact_arrests (arrest_number, report_id, agent_key, arrest_occurred_date_time);
            INSERT INTO fact_arrests VALUES
              ('a1','r1','agentA','2024-01-01 12:00:00'),
              ('a2','r1','agentA','2024-01-05 12:00:00'),
              ('a3','r1','agentB','2024-01-06 12:00:00'),
              ('a4','r9','agentB','2024-01-07 12:00:00'),
              ('a5',NULL,NULL,'2024-01-08 12:00:00'),
              ('a6',NULL,NULL,'2024-01-09 12:00:00'),
              ('old','r2','agentA','2023-12-31 12:00:00'),
              ('undated',NULL,NULL,NULL), ('next',NULL,NULL,'2025-01-01 00:00:00');
            CREATE TABLE dim_date (full_date, is_weekend);
            INSERT INTO dim_date VALUES ('2024-01-01',FALSE), ('2024-01-05',FALSE),
              ('2024-01-06',TRUE), ('2024-01-07',TRUE), ('2024-01-08',FALSE);
            CREATE TABLE bridge_crime_shooting_types (crime_id, shooting_type_id);
            INSERT INTO bridge_crime_shooting_types VALUES
              ('c1','t1'),('c1','t2'),('c2','t1'),('c3','t1'),('c4','t1'),('c6','blank');
            CREATE TABLE dim_shooting_type (shooting_type_id, description);
            INSERT INTO dim_shooting_type VALUES ('t1','SHOOTING'),('t2','SHOTS FIRED'),('blank',' ');
            CREATE TABLE dim_agent (agent_key, officer_id);
            INSERT INTO dim_agent VALUES ('agentA','officer-A'),('agentB','officer-B');
        ''')

    def query(self, name, start='2024-01-01', end='2025-01-01'):
        sql = (panel.ROOT / 'curiosidades' / f'{name}.sql').read_text()
        self.assertNotIn('MARTS.', sql)
        sql = sql.replace('DEV_GOLD.GOLD.', '').replace('TO_DATE(%s)', 'DATE(?)')
        sql = sql.replace('EXTRACT(HOUR FROM offense_date_time)', "CAST(STRFTIME('%H', offense_date_time) AS INTEGER)")
        sql = sql.replace('CAST(a.arrest_occurred_date_time AS DATE)', 'DATE(a.arrest_occurred_date_time)')
        return [dict(r) for r in self.db.execute(sql, (start, end))]

    def test_nombres_por_especie_empates_ausencias_y_limites(self):
        rows = self.query('nombres')
        self.assertEqual([(r['species'], r['animal_name'], r['license_count']) for r in rows],
                         [('CAT', 'MILO', 2), ('DOG', 'LUNA', 2), ('DOG', 'MAX', 2)])
        dog = rows[1]
        self.assertEqual((dog['total_licenses'], dog['unnamed_licenses'], dog['undated_licenses']), (5, 1, 1))
        rows = self.query('nombres', '2025-01-01', '2026-01-01')
        self.assertEqual(rows[0]['license_count'], 0)
        self.assertEqual(rows[1]['animal_name'], 'OTRO')

    def test_horas_ocurrencia_empates_y_sin_fecha(self):
        rows = self.query('horas')
        self.assertEqual([r['hour'] for r in rows if r['position'] == 1], [10, 11])
        self.assertTrue(all(r['total_crimes'] == 6 and r['undated_crimes'] == 1 for r in rows))

    def test_bloques_no_calles_y_ocultados_fuera(self):
        rows = self.query('vehiculos')
        self.assertEqual([r['block_address'] for r in rows], ['100 BLOCK A ST', '200 BLOCK B ST'])
        self.assertTrue(all(r['crime_count'] == 2 and r['excluded_thefts'] == 2 and r['total_thefts'] == 6 for r in rows))

    def test_detenciones_fechas_de_ocurrencia_y_cobertura_calendario(self):
        row, = self.query('semana')
        self.assertEqual(row, {'weekday_count': 3, 'weekend_count': 2,
                               'unclassified_arrests': 1, 'undated_arrests': 1})

    def test_tiroteos_sin_multiplicar_etiquetas_ni_detenciones(self):
        row, = self.query('tiroteos')
        # c3 comparte informe con una detención anterior: no se afirma posterioridad.
        self.assertEqual(row, {'shooting_count': 4, 'with_arrest': 3, 'missing_report': 1})

    def test_agentes_id_empates_y_ausencias(self):
        rows = self.query('agentes')
        self.assertEqual([r['officer_id'] for r in rows], ['officer-A', 'officer-B'])
        self.assertTrue(all(r['arrest_count'] == 2 and r['unidentified_arrests'] == 2 for r in rows))

    def test_periodo_vacio_no_se_confunde_con_error(self):
        for name in ['nombres', 'horas', 'vehiculos', 'semana', 'tiroteos', 'agentes']:
            rows = self.query(name, '2026-01-01', '2027-01-01')
            self.assertTrue(rows, name)
        self.assertEqual(self.query('tiroteos', '2026-01-01', '2027-01-01')[0]['shooting_count'], 0)


class CuriousBackendTest(unittest.TestCase):
    def test_periodos_y_seis_consultas_parametrizadas(self):
        connection = unittest.mock.MagicMock()
        with patch.object(panel, 'conectar', return_value=connection), patch.object(panel, 'registros', return_value=[{'count': 1}]) as rows:
            result = panel.curiosidades('2024')
        self.assertEqual(rows.call_count, 6)
        self.assertTrue(all(call.args[2] == ('2024-01-01', '2025-01-01') for call in rows.call_args_list))
        self.assertEqual(result['avisos'], {})
        json.dumps(result, allow_nan=False)

    def test_todos_y_fallo_independiente_sin_filtrar_error_del_conector(self):
        connection = unittest.mock.MagicMock()
        def read(cur, file, args):
            self.assertEqual(args, ('2024-01-01', '2027-01-01'))
            if file.endswith('tiroteos.sql'):
                raise RuntimeError('credencial privada del conector')
            return [{'count': 1}]
        with patch.object(panel, 'conectar', return_value=connection), patch.object(panel, 'registros', side_effect=read):
            result = panel.curiosidades('todos')
        self.assertEqual(len(result['datos']), 5)
        self.assertEqual(list(result['avisos']), ['tiroteos'])
        self.assertNotIn('privada', json.dumps(result))

    def test_anio_no_admitido_no_conecta(self):
        with patch.object(panel, 'conectar') as connect:
            for year in ['2023', '2027', '2024 OR 1=1']:
                with self.assertRaises(ValueError):
                    panel.curiosidades(year)
            connect.assert_not_called()

    def test_registros_convierte_decimal(self):
        cursor = unittest.mock.MagicMock()
        cursor.description = [('COUNT',)]
        cursor.__iter__.return_value = iter([(Decimal('42'),)])
        self.assertEqual(panel.registros(cursor, 'curiosidades/horas.sql', ('2024-01-01', '2025-01-01')), [{'count': 42.0}])
