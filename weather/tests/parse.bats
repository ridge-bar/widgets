#!/usr/bin/env bats
# Runs the vendored weather_parse.py / weather_popup_render.py against fixture
# j1 JSON and asserts exact output. Fixture hourly slots are uniform per day
# (same desc/chanceofrain/chanceofthunder/precipMM at every timestamp) so
# output does not depend on the wall-clock hour the tests run at.

setup() {
  PLUGIN_DIR="${BATS_TEST_DIRNAME}/.."
  FIXTURES="${BATS_TEST_DIRNAME}/fixtures"
}

@test "weather_parse.py prints temp/desc/near for a clear-weather fixture" {
  run python3 "${PLUGIN_DIR}/weather_parse.py" < "${FIXTURES}/weather_j1_clear.json"
  [ "$status" -eq 0 ]
  [ "$output" = $'22°C\tSunny\tclear' ]
}

@test "weather_parse.py prints temp/desc/near for a rain fixture" {
  run python3 "${PLUGIN_DIR}/weather_parse.py" < "${FIXTURES}/weather_j1_rain.json"
  [ "$status" -eq 0 ]
  [ "$output" = $'14°C\tLight rain shower\train' ]
}

@test "weather_popup_render.py prints current conditions and 3-day forecast for the clear fixture" {
  run python3 "${PLUGIN_DIR}/weather_popup_render.py" < "${FIXTURES}/weather_j1_clear.json"
  [ "$status" -eq 0 ]
  expected=$'now|Now|22°C  Sunny\nfeels|Feels like|21°C\nhumidity|Humidity|40%\nwind|Wind|10 km/h NW\nrainchance|Rain chance|0%\nprecip|Precip (6h)|0.0 mm\n1|Today|25°/15°  Clear\n2|Tomorrow|26°/16°  Clear\n3|Wed|24°/14°  Clear'
  [ "$output" = "$expected" ]
}

@test "weather_popup_render.py prints current conditions and 3-day forecast for the rain fixture" {
  run python3 "${PLUGIN_DIR}/weather_popup_render.py" < "${FIXTURES}/weather_j1_rain.json"
  [ "$status" -eq 0 ]
  expected=$'now|Now|14°C  Light rain shower\nfeels|Feels like|12°C\nhumidity|Humidity|88%\nwind|Wind|22 km/h SW\nrainchance|Rain chance|80%\nprecip|Precip (6h)|0.0 mm\n1|Today|16°/11°  Patchy rain possible\n2|Tomorrow|17°/12°  Moderate rain\n3|Wed|15°/10°  Patchy rain possible'
  [ "$output" = "$expected" ]
}
