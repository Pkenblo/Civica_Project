"""Renderiza la macro instalada de dbt_utils para las regresiones sin Snowflake."""

from pathlib import Path
from types import SimpleNamespace

from jinja2 import Environment, StrictUndefined


ROOT = Path(__file__).resolve().parents[2]


def dbt_utils_namespace():
    path = ROOT / 'dbt_packages/dbt_utils/macros/sql/generate_surrogate_key.sql'
    if not path.exists():
        raise RuntimeError('Ejecuta dbt deps antes de las regresiones locales.')
    module = Environment(undefined=StrictUndefined, extensions=['jinja2.ext.do']).from_string(
        path.read_text()
    ).make_module({
        'var': lambda name, default=None: default,
        'dbt': SimpleNamespace(
            type_string=lambda: 'varchar',
            concat=lambda fields: ' || '.join(fields),
            hash=lambda expression: f'md5(cast({expression} as varchar))',
        ),
    })
    return SimpleNamespace(generate_surrogate_key=module.default__generate_surrogate_key)
