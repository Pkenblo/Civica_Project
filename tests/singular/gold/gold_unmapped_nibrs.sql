-- Operational signal, not a data error or a requirement to assign a severity.
{{ config(severity='warn') }}

select offense_code, offense_description, group_ab, crime_against_category
from {{ ref('dim_nibrs') }}
where severity = 'sin_clasificar'
