select nibrs_key, offense_code, offense_description, group_ab, crime_against_category
from {{ ref('nibrs') }}
