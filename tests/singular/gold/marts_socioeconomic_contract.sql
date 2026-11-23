{% set marts = [
    ('mart_crimes_socioeconomic', ref('mart_crimes_socioeconomic'), 'crime_id'),
    ('mart_arrest_socioeconomic', ref('mart_arrest_socioeconomic'), 'arrest_number')
] %}

{% for model_name, relation, id_column in marts %}
select '{{ model_name }}' as mart_name, cast({{ id_column }} as varchar) as event_id
from {{ relation }}
where acs_year is distinct from 2024
   or acs_period is distinct from '2020–2024'
   or income_quintile not between 1 and 5
   or median_household_income < 0
   or income_margin_of_error < 0
   or population < 0
   or median_home_value < 0
   or median_monthly_rent < 0
{% if id_column == 'arrest_number' %}
   or postal_year_arrest_count < 1
   or postal_year_arrests_per_1000 < 0
{% endif %}
{% if not loop.last %}
union all
{% endif %}
{% endfor %}
