"""Prueba visual con Playwright y respuestas sintéticas, sin conexión a Snowflake.

Uso: python ui_smoke.py http://127.0.0.1:8765 --screenshots /tmp/opencode/civica-ui
El servidor local debe estar iniciado. Requiere playwright y Chromium.
"""

import argparse
import json
import shutil
from pathlib import Path

from playwright.sync_api import expect, sync_playwright


def fixtures():
    rows, zones, points, arrests, counts = [], [], [], [], []
    for i in range(9):
        cp = str(98101 + i)
        lon, lat = -122.37 + (i % 3) * .032, 47.57 + (i // 3) * .032
        geometry = {'type': 'Polygon', 'coordinates': [[
            [lon, lat], [lon + .028, lat], [lon + .028, lat + .028],
            [lon, lat + .028], [lon, lat],
        ]]}
        rows.append(['geo', cp, geometry])
        zones.append({
            'cp': cp, 'geometry': geometry, 'population': 1000 * (i + 1),
            'has_socioeconomic_data': True,
            'median_household_income': 45000 + i * 12000,
            'median_monthly_rent': 900 + i * 200,
            'median_home_value': 200000 + i * 100000,
            'income_margin_of_error': 1200, 'zcta_name': cp,
        })
        category = 'Delitos contra vehículos' if i % 2 else 'Hurtos generales'
        code = '240' if i % 2 else '23A'
        points.append([lat + .014, lon + .014, category, code, 'Tipo de prueba',
                       i + 1, cp, 'Bloque de prueba', 'Barrio de prueba'])
        arrests.append({'latitude': lat + .014, 'longitude': lon + .014,
                        'cp': cp, 'arrest_count': i + 1})
        for year in [2024, 2025, 2026]:
            dogs, cats = (30 + i * 10, 100 - i * 10)
            rows.append(['comparacion', cp, year, i * 3 + 2,
                         dogs, cats, 0, 0, i * 4 + 1,
                         dogs * 3, cats * 3, 0, 0, i + 1])
            counts.append({'cp': cp, 'year': year, 'has_postal_reference': True,
                           'has_point': True, 'arrest_count': i + 1,
                           'crime_count': i + 1, 'nibrs_category': category,
                           'nibrs_code': code, 'nibrs_description': 'Tipo de prueba'})
    data = {'datos': {'date': '2026-01-01T00:00:00Z', 'rows': rows}, 'aviso': ''}
    crimes = {'mes': '2024-01', 'filas': points, 'zonas': zones, 'recuentos': counts}
    socio = {'anio': 2024, 'anios': [2024, 2025, 2026], 'puntos': arrests,
             'zonas': zones, 'recuentos': counts, 'fecha': '2026-01-01T00:00:00Z'}
    return data, crimes, socio


def facts_fixture(year):
    data = {
        'nombres': [{'species': 'DOG', 'animal_name': 'LUNA', 'license_count': 42, 'total_licenses': 120, 'unnamed_licenses': 2, 'undated_licenses': 1},
                    {'species': 'CAT', 'animal_name': 'MILO', 'license_count': 30, 'total_licenses': 80, 'unnamed_licenses': 1, 'undated_licenses': 0}],
        'horas': [{'hour': h, 'crime_count': 40 if h == 23 else 1, 'position': 1 if h == 23 else 2, 'total_crimes': 63, 'undated_crimes': 3} for h in range(24)],
        'vehiculos': [{'block_address': '100 BLOCK A ST', 'crime_count': 10, 'total_thefts': 30, 'excluded_thefts': 2},
                      {'block_address': '200 BLOCK B ST', 'crime_count': 10, 'total_thefts': 30, 'excluded_thefts': 2}],
        'semana': [{'weekday_count': 500, 'weekend_count': 250, 'unclassified_arrests': 0, 'undated_arrests': 2}],
        'tiroteos': [{'shooting_count': 5, 'with_arrest': 2, 'missing_report': 1}],
        'agentes': [{'officer_id': 'SPD-042', 'arrest_count': 12, 'total_arrests': 20, 'unidentified_arrests': 1}],
    }
    warnings = {}
    if year == '2026':
        data = {'nombres': [{'species': s, 'animal_name': None, 'license_count': 0} for s in ['DOG', 'CAT']],
                'horas': [{'hour': None, 'position': None, 'crime_count': 0, 'total_crimes': 0}],
                'vehiculos': [{'block_address': None, 'total_thefts': 0, 'excluded_thefts': 0}],
                'semana': [{'weekday_count': 0, 'weekend_count': 0}],
                'tiroteos': [{'shooting_count': 0, 'with_arrest': 0}],
                'agentes': [{'officer_id': None, 'total_arrests': 0}]}
    elif year == '2025':
        del data['agentes']
        warnings['agentes'] = 'No se pudo consultar este dato. Revisa los permisos SELECT en Gold.'
    return {'anio': year, 'datos': data, 'avisos': warnings, 'fecha': '2026-01-01T00:00:00Z'}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('url')
    parser.add_argument('--screenshots', type=Path, default=Path('/tmp/opencode/civica-ui'))
    parser.add_argument('--data', type=Path, help='Lectura local opcional para el mapa postal')
    args = parser.parse_args()
    args.screenshots.mkdir(parents=True, exist_ok=True)
    data, crimes, socio = fixtures()
    if args.data:
        data = {'datos': json.loads(args.data.read_text()), 'aviso': ''}
    requests, errors = [], []

    def respond(route):
        path = route.request.url.split(args.url.rstrip('/'), 1)[1]
        requests.append(path)
        if path == '/datos':
            payload = data
        elif path.startswith('/puntos/'):
            payload = {**crimes, 'mes': path.rsplit('/', 1)[1]}
        elif path.startswith('/curiosidades/'):
            payload = facts_fixture(path.rsplit('/', 1)[1])
        else:
            payload = {**socio, 'anio': int(path.rsplit('/', 1)[1])}
        route.fulfill(json=payload)

    def check_width(page):
        assert page.evaluate('document.documentElement.scrollWidth <= innerWidth'), 'Desbordamiento horizontal'

    with sync_playwright() as p:
        browser = p.chromium.launch(headless=True, executable_path=shutil.which('chromium'))
        context = browser.new_context(viewport={'width': 1440, 'height': 1050}, reduced_motion='reduce')
        context.route('**/datos', respond)
        context.route('**/puntos/*', respond)
        context.route('**/socio/*', respond)
        context.route('**/curiosidades/*', respond)
        # Las teselas no forman parte del contrato local y requieren Internet.
        context.route('https://tile.openstreetmap.org/**', lambda route: route.abort())
        page = context.new_page()
        page.on('pageerror', lambda error: errors.append(str(error)))
        page.goto(args.url)
        page.wait_for_load_state('networkidle')
        assert page.locator('#panel').is_visible()
        assert page.locator('#comparativas table').count() == 3
        assert page.locator('#anio').input_value() == '2024'
        assert page.locator('#modo').is_checked()
        assert page.locator('#min-licenses').is_checked()
        assert page.locator('.view-nav button').all_text_contents() == ['', '', '', '']
        for button in page.locator('.view-nav button').all():
            assert button.get_attribute('aria-label')
            assert button.locator('svg').is_visible()
        initial = page.locator('#comparativas tbody').all_text_contents()
        page.screenshot(path=str(args.screenshots / 'zonas-desktop.png'), full_page=True)
        check_width(page)
        page.select_option('#animal', 'ambos')
        assert page.locator('.paired-marker').count() > 0
        page.select_option('#serie', 'hurtos')
        assert 'hurtos' in page.locator('#map-title').inner_text()
        page.select_option('#serie', 'vehiculos')
        assert page.locator('#comparativas tbody').all_text_contents() == initial
        page.uncheck('#map-min-licenses')
        assert not page.locator('#min-licenses').is_checked()
        page.check('#min-licenses')
        assert page.locator('#map-min-licenses').is_checked()
        page.select_option('#anio', '2025')
        assert page.locator('#group-year').input_value() == '2025'
        page.select_option('#group-year', 'todos')
        page.select_option('#anio', '2024')
        page.select_option('#group-year', '2024')
        assert requests == ['/datos'], 'Los filtros postales no deben consultar de nuevo'

        page.click('#open-points')
        page.wait_for_load_state('networkidle')
        assert page.locator('#points-view').is_visible()
        assert page.locator('#points-comparisons table').count() == 3
        assert '45 delitos' in page.locator('#points-status').inner_text()
        page.select_option('#points-level', '0')
        assert '6 delitos' in page.locator('#points-status').inner_text()
        page.click('#points-reset')
        assert '45 delitos' in page.locator('#points-status').inner_text()
        page.locator('.crime-chart-type').first.select_option(index=1)
        assert page.locator('.crime-chart-type').nth(1).input_value() == ''
        page.screenshot(path=str(args.screenshots / 'delitos-desktop.png'), full_page=True)
        check_width(page)

        page.click('#open-socio')
        page.wait_for_load_state('networkidle')
        assert page.locator('#socio-comparisons table').count() == 3
        assert '45 detenciones' in page.locator('#socio-status').inner_text()
        page.select_option('#socio-color', 'median_monthly_rent')
        page.uncheck('#socio-points')
        page.check('#socio-points')
        page.screenshot(path=str(args.screenshots / 'detenciones-desktop.png'), full_page=True)
        check_width(page)
        page.select_option('#socio-year', '2025')
        page.wait_for_load_state('networkidle')
        expect(page.locator('#socio-status')).to_contain_text('2025 ·')

        page.get_by_role('button', name='Datos curiosos', exact=True).click()
        expect(page.locator('#facts-status')).to_contain_text('Periodo: 2024')
        assert page.locator('.fact-card').count() == 6
        expect(page.locator('#fact-nombres')).to_contain_text('LUNA')
        expect(page.locator('#fact-nombres')).to_contain_text('MILO')
        expect(page.locator('#fact-horas')).to_contain_text('23:00–00:00')
        expect(page.locator('#fact-vehiculos')).to_contain_text('200 BLOCK B ST')
        expect(page.locator('#fact-semana')).to_contain_text('25 % más')
        expect(page.locator('#fact-tiroteos')).to_contain_text('2 de 5')
        expect(page.locator('#fact-agentes')).to_contain_text('SPD-042')
        page.screenshot(path=str(args.screenshots / 'curiosidades-desktop.png'), full_page=True)
        assert page.locator('#facts-year').input_value() == '2024'
        page.select_option('#facts-year', '2026')
        expect(page.locator('#facts-status')).to_contain_text('Periodo: 2026')
        expect(page.locator('#fact-tiroteos')).to_contain_text('Sin tiroteos registrados')
        assert 'NaN' not in page.locator('#facts-grid').inner_text()
        page.select_option('#facts-year', '2025')
        expect(page.locator('#facts-status')).to_contain_text('1 dato no disponible')
        expect(page.locator('#fact-agentes')).to_contain_text('No disponible')
        page.select_option('#facts-year', 'todos')
        expect(page.locator('#facts-status')).to_contain_text('Periodo: 2024–2026')
        count_before = len(requests)
        page.select_option('#facts-year', '2024')
        assert len(requests) == count_before, 'Los periodos ya consultados se conservan en memoria'
        page.click('#facts-reload')
        expect(page.locator('#facts-status')).to_contain_text('Periodo: 2024')
        assert len(requests) == count_before + 1

        for width, height in [(375, 812), (768, 1024), (1024, 768), (1440, 900)]:
            page.set_viewport_size({'width': width, 'height': height})
            for tab, view in [('open-zones', 'zones'), ('open-points', 'points'), ('open-socio', 'socio'), ('open-facts', 'facts')]:
                page.locator('#' + tab).click()
                assert page.locator('#' + tab).get_attribute('aria-pressed') == 'true'
                assert page.locator('.view-nav button[aria-pressed="true"]').count() == 1
                assert page.locator('#' + tab + ' svg').is_visible()
                assert page.locator('#' + view + '-view').is_visible()
                check_width(page)
                if width == 375:
                    page.screenshot(path=str(args.screenshots / f'{view}-mobile.png'), full_page=True)

        context.route('**/curiosidades/*', lambda route: route.fulfill(status=503, json={'aviso': 'No se pudieron cargar los datos curiosos.'}))
        page.click('#facts-reload')
        expect(page.locator('#facts-status')).to_contain_text('reintentar')
        assert page.locator('.fact-card').count() == 0
        assert page.locator('#facts-reload').is_enabled()

        page.set_viewport_size({'width': 1440, 'height': 1000})
        page.goto(args.url.rstrip('/') + '/correlaciones.html')
        page.wait_for_load_state('networkidle')
        assert page.locator('#matrix button').count() == 8
        assert page.locator('#absolute circle').count() > 0
        page.locator('#matrix button').nth(3).click()
        assert page.locator('#species').input_value() == '5'
        assert page.locator('#crime').input_value() == '3'
        dot = page.locator('#absolute circle').first
        dot.focus()
        dot.press('Enter')
        assert 'CP ' in page.locator('#detail').inner_text()
        page.screenshot(path=str(args.screenshots / 'correlaciones-desktop.png'), full_page=True)
        check_width(page)
        page.set_viewport_size({'width': 375, 'height': 812})
        check_width(page)
        page.screenshot(path=str(args.screenshots / 'correlaciones-mobile.png'), full_page=True)
        context.route('**/datos', lambda route: route.fulfill(
            status=503, json={'aviso': 'No se pudo cargar el panel. Vuelve a abrir el lanzador.'}))
        page.goto(args.url)
        page.wait_for_load_state('networkidle')
        expect(page.locator('#source')).to_contain_text('Vuelve a abrir el lanzador')
        assert not page.locator('#panel').is_visible()
        assert not errors, errors
        browser.close()
    print('OK: tres mapas, seis curiosidades, periodos, empates, vacíos, errores, correlaciones y cuatro tamaños; sin errores JS.')
    print(f'Capturas: {args.screenshots}')


if __name__ == '__main__':
    main()
