"""Extrae observaciones CP-año de los dos CSV para el informe HTML local."""
import csv
import json
import re
from pathlib import Path

ROOT = Path(__file__).resolve().parent
IN = ROOT.parent / 'datos_ejemplo'
SPECIES = ('DOG', 'CAT', 'GOAT', 'PIG')


def leer(nombre, delito):
    rows = {}
    with (IN / nombre).open(encoding='utf-8-sig', newline='') as f:
        for row in csv.DictReader(f):
            key = int(row['YEAR']), row['CP']
            counts = tuple(int(row[s + '_LICENSE_COUNT']) for s in SPECIES)
            n = int(row[delito])
            if (key in rows or not re.fullmatch(r'\d{5}', key[1]) or min(*counts, n) < 0
                    or sum(counts) != int(row['PET_LICENSE_COUNT'])):
                raise ValueError(f'Clave o recuentos incorrectos en {nombre}: {key}')
            rows[key] = n, counts
    return rows


if __name__ == '__main__':
    csv.field_size_limit(64 * 1024**2)
    theft = leer('mart_robos.csv', 'THEFT_COUNT')
    motor = leer('mart_robos_coches.csv', 'VEHICLE_THEFT_COUNT')
    if theft.keys() != motor.keys():
        raise ValueError('Los CSV no contienen las mismas parejas CP-año.')
    data = []
    for key in sorted(theft):
        n, counts = theft[key]
        m, other = motor[key]
        if counts != other:
            raise ValueError(f'Licencias diferentes para {key}')
        data.append([*key, n, m, *counts])
    (ROOT / 'marts-datos.js').write_text('const observaciones = ' + json.dumps(data, separators=(',', ':')) + ';\n')
    print(f'{len(data)} observaciones CP-año verificadas.')
