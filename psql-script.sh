#!/bin/bash
find_deployrc() {
  local dir="$PWD"
  while [[ "$dir" != "/" ]]; do
    if [[ -f "$dir/.deployrc" ]]; then
      echo "$dir"
      return
    fi
    dir=$(dirname "$dir")
  done
}
DEPLOY_CONFIG_DIR=$(find_deployrc)

# Obtener parámetros
while getopts "d:e:f:t:g:" opt; do
  case $opt in
    d) db_name="$OPTARG" ;;
    e) env="$OPTARG" ;;
    f) sql_file="$OPTARG" ;;
    t) sql_dir="$OPTARG" ;;  # Directorio con scripts SQL
    g) tag="$OPTARG" ;;  # Directorio con scripts SQL
    *) echo "Uso: pgsql -d <base_de_datos> -e <entorno> [-f <archivo.sql>] [-t <directorio_sql>]"
       exit 1 ;;
  esac
done

# Verificar que los parámetros requeridos fueron ingresados
if [[ -z "$env" || -z "$db_name" ]]; then
  echo "Error: Debes especificar la base de datos (-d) y el entorno (-e)."
  exit 1
fi

# Capturar fecha, hora y entorno
fecha_hora=$(date +"%Y-%m-%d %H:%M:%S")
fecha_actual=$(date +"%Y_%m_%d")  # Día en formato YYYY-MM-DD
hora_actual=$(date +"%H_%M_%S")      # Hora y minutos en formato HH-MM
CONFIG_FILE="$HOME/.pg_service.conf"
LOG_DIR="$DEPLOY_CONFIG_DIR/"
DEPLOYED_DIR="$DEPLOY_CONFIG_DIR/dbscripts/$db_name/_deployed/$env/"
LOG_FILE="${LOG_DIR}.log-script.log"

# Verificar si el archivo de configuración existe
if [[ ! -f "$CONFIG_FILE" ]]; then
  echo "Error: No se encontró el archivo de configuración $CONFIG_FILE"
  exit 1
fi

# Extraer el HOST desde la sección correspondiente
HOST=$(awk -v section="[$env]" -F '=' '
    $0 == section {flag=1; next}
    flag && /host=/ {print $2; flag=0}
' "$CONFIG_FILE")

# Verificar que se haya obtenido un HOST válido
if [[ -z "$HOST" ]]; then
  echo "Error: No se encontró un 'host=' en la sección [$env] de $CONFIG_FILE"
  exit 1
fi

# Crear directorios si no existen
mkdir -p "$LOG_DIR" "$DEPLOYED_DIR"

# Función para ejecutar un script SQL y moverlo a `deployed/YYYY-MM-DD/HH-MM/env/`
execute_sql() {
  local sql_file="$1"
  local nombre_fichero=$(basename "$sql_file")
  # Verificar si el script ya se ejecutó antes

  if [[ -f "$LOG_FILE" ]] && grep -q "$env | $nombre_fichero | $HOST | $db_name" "$LOG_FILE"; then
    echo "⚠️ Advertencia: El script [$sql_file] ya fue ejecutado en [$env] con la base de datos [$db_name]."
    read -p "¿Quieres ejecutarlo nuevamente? (s/n): " confirmacion
    if [[ "$confirmacion" != "s" ]]; then
      echo "Operación cancelada para [$sql_file]."
      return
    fi
  fi

  nombre_fichero=$(basename "$sql_file")
  # Ejecutar el comando SQL
  PGSERVICE="$env" psql -v env="$env" -d "$db_name" -f "$sql_file"
  if [[ $? -ne 0 ]]; then
    echo "❌ Error: Falló la ejecución de [$sql_file]"
    exit 1
  fi

  # Registrar en el log y mover el archivo a `deployed/YYYY-MM-DD/HH-MM/env/`
  echo "$fecha_hora | $env | $nombre_fichero | $HOST | $db_name | psql -d $db_name -f $sql_file" >> "$LOG_FILE"
  git mv "$sql_file" "$DEPLOYED_DIR/" >/dev/null 2>&1 || mv "$sql_file" "$DEPLOYED_DIR/" >/dev/null 2>&1
  git add "$LOG_FILE" >/dev/null 2>&1 && git commit -m "Nuevos cambios de log scripts" >/dev/null 2>&1 && git push 1>/dev/null >/dev/null 2>&1
  echo "✅ Script [$sql_file] ejecutado y movido a [$DEPLOYED_DIR]"
}

# Si se pasa un archivo específico (-f), ejecutarlo
if [[ -n "$sql_file" ]]; then
  execute_sql "$sql_file"
fi

# Si se pasa un directorio (-D), ejecutar todos los scripts en orden
if [[ -n "$sql_dir" ]]; then
  echo "🔹 Ejecutando todos los scripts en [$sql_dir] por orden de nombre..."
  for file in $(ls -1 "$sql_dir"/*.sql | sort); do
    execute_sql "$file"
  done
fi
