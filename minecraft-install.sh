#!/bin/bash
#
# Minecraft Server Manager - Instalador
# Ejecutar como root en un VPS limpio
#

set -e

# Colores
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

echo -e "${CYAN}"
echo "╔═══════════════════════════════════════════════╗"
echo "║   Minecraft Server Manager - Instalador       ║"
echo "╚═══════════════════════════════════════════════╝"
echo -e "${NC}"

# Verificar root
if [ "$EUID" -ne 0 ]; then
    echo -e "${RED}Error: Ejecuta este script como root${NC}"
    exit 1
fi

# Detectar distro
if [ -f /etc/debian_version ]; then
    PKG_MANAGER="apt"
    PKG_UPDATE="apt update"
    PKG_INSTALL="apt install -y"
elif [ -f /etc/redhat-release ]; then
    PKG_MANAGER="yum"
    PKG_UPDATE="yum check-update || true"
    PKG_INSTALL="yum install -y"
else
    echo -e "${RED}Distribucion no soportada. Usa Debian/Ubuntu o RHEL/CentOS.${NC}"
    exit 1
fi

echo -e "${YELLOW}[1/4] Actualizando repositorios...${NC}"
$PKG_UPDATE > /dev/null 2>&1

echo -e "${YELLOW}[2/4] Instalando dependencias (Java 17, screen)...${NC}"
if [ "$PKG_MANAGER" = "apt" ]; then
    $PKG_INSTALL openjdk-17-jre-headless screen > /dev/null 2>&1
else
    $PKG_INSTALL java-17-openjdk-headless screen > /dev/null 2>&1
fi

echo -e "${YELLOW}[3/4] Creando directorio /opt/minecraft...${NC}"
mkdir -p /opt/minecraft/profiles

echo -e "${YELLOW}[4/4] Instalando Minecraft Server Manager...${NC}"

# Crear el script mc
cat > /opt/minecraft/mc << 'MCSCRIPT'
#!/usr/bin/env python3
"""
Minecraft Server Manager - CLI para gestionar perfiles de servidor
"""

import os
import sys
import json
import subprocess
import shutil
import urllib.request
import urllib.parse
from pathlib import Path
from datetime import datetime

# Configuracion
BASE_DIR = Path("/opt/minecraft")
PROFILES_DIR = BASE_DIR / "profiles"
ACTIVE_FILE = BASE_DIR / "active_profile"
SCREEN_NAME = "minecraft"

# Colores ANSI
class Colors:
    HEADER = '\033[95m'
    BLUE = '\033[94m'
    CYAN = '\033[96m'
    GREEN = '\033[92m'
    YELLOW = '\033[93m'
    RED = '\033[91m'
    END = '\033[0m'
    BOLD = '\033[1m'

def color(text, c):
    return f"{c}{text}{Colors.END}"

def clear():
    os.system('clear')

# ============ UTILIDADES ============

def get_active_profile():
    """Obtiene el perfil activo actual"""
    if ACTIVE_FILE.exists():
        return ACTIVE_FILE.read_text().strip()
    profiles = list_profiles()
    if profiles:
        return profiles[0]
    return None

def set_active_profile(name):
    """Establece el perfil activo"""
    ACTIVE_FILE.write_text(name)

def list_profiles():
    """Lista todos los perfiles disponibles"""
    if not PROFILES_DIR.exists():
        return []
    return [d.name for d in PROFILES_DIR.iterdir() if d.is_dir() and (d / "profile.json").exists()]

def load_profile(name):
    """Carga la configuracion de un perfil"""
    profile_file = PROFILES_DIR / name / "profile.json"
    if profile_file.exists():
        return json.loads(profile_file.read_text())
    return None

def save_profile(name, data):
    """Guarda la configuracion de un perfil"""
    profile_file = PROFILES_DIR / name / "profile.json"
    profile_file.write_text(json.dumps(data, indent=4))

def is_server_running():
    """Verifica si el servidor esta corriendo"""
    result = subprocess.run(['screen', '-list'], capture_output=True, text=True)
    return SCREEN_NAME in result.stdout

def get_profile_dir(name):
    """Obtiene el directorio de un perfil"""
    return PROFILES_DIR / name

# ============ SERVIDOR ============

def start_server():
    """Inicia el servidor con el perfil activo"""
    if is_server_running():
        print(color("El servidor ya esta corriendo!", Colors.YELLOW))
        return

    profile_name = get_active_profile()
    if not profile_name:
        print(color("No hay perfil activo. Crea uno primero.", Colors.RED))
        return

    profile = load_profile(profile_name)
    profile_dir = get_profile_dir(profile_name)
    jar_file = profile['jar_file']
    ram_min = profile.get('ram_min', '2G')
    ram_max = profile.get('ram_max', '5G')

    # Comando de inicio
    java_cmd = f"""cd {profile_dir} && java -Xms{ram_min} -Xmx{ram_max} \\
        -XX:+UseG1GC -XX:+ParallelRefProcEnabled -XX:MaxGCPauseMillis=200 \\
        -XX:+UnlockExperimentalVMOptions -XX:+DisableExplicitGC \\
        -XX:G1NewSizePercent=30 -XX:G1MaxNewSizePercent=40 \\
        -XX:G1HeapRegionSize=8M -XX:G1ReservePercent=20 \\
        -jar {jar_file} nogui"""

    # Iniciar en screen con reinicio automatico
    start_script = f'''
    while true; do
        echo "[$(date)] Iniciando servidor perfil: {profile_name}"
        {java_cmd}
        echo "[$(date)] Servidor detenido. Reiniciando en 10s... (Ctrl+C para cancelar)"
        sleep 10
    done
    '''

    subprocess.run(['screen', '-dmS', SCREEN_NAME, 'bash', '-c', start_script])
    print(color(f"Servidor iniciado con perfil '{profile_name}'", Colors.GREEN))
    print(f"  Version: {profile['version']}")
    print(f"  RAM: {ram_min} - {ram_max}")
    print(f"\n  Usa 'mc console' para ver la consola")

def stop_server():
    """Detiene el servidor"""
    if not is_server_running():
        print(color("El servidor no esta corriendo.", Colors.YELLOW))
        return

    # Enviar comando stop
    subprocess.run(['screen', '-S', SCREEN_NAME, '-p', '0', '-X', 'stuff', 'stop\n'])
    print("Enviando comando 'stop'...")

    import time
    time.sleep(5)

    # Cerrar screen
    subprocess.run(['screen', '-S', SCREEN_NAME, '-X', 'quit'], capture_output=True)
    print(color("Servidor detenido.", Colors.GREEN))

def server_console():
    """Abre la consola del servidor"""
    if not is_server_running():
        print(color("El servidor no esta corriendo.", Colors.YELLOW))
        return

    print(color("\n╔═══════════════════════════════════════════╗", Colors.CYAN))
    print(color("║  Para SALIR: pulsa Ctrl+A, luego D        ║", Colors.YELLOW))
    print(color("║  (NO uses Ctrl+C, eso mata el servidor)   ║", Colors.RED))
    print(color("╚═══════════════════════════════════════════╝\n", Colors.CYAN))

    input("Pulsa Enter para continuar...")
    subprocess.run(['screen', '-r', SCREEN_NAME])

def server_status():
    """Muestra el estado del servidor"""
    profile_name = get_active_profile()
    running = is_server_running()

    print(f"\n  Perfil activo: {color(profile_name or 'Ninguno', Colors.CYAN)}")
    if running:
        print(f"  Estado: {color('ONLINE', Colors.GREEN)}")
    else:
        print(f"  Estado: {color('OFFLINE', Colors.RED)}")
    print()

# ============ PERFILES ============

def show_profiles():
    """Muestra todos los perfiles"""
    profiles = list_profiles()
    active = get_active_profile()

    print(f"\n  {color('Perfiles disponibles:', Colors.BOLD)}")
    print("  " + "-" * 40)

    if not profiles:
        print("  No hay perfiles. Usa 'mc new' para crear uno.")
        return

    for name in profiles:
        profile = load_profile(name)
        marker = color("*", Colors.GREEN) if name == active else " "
        version = profile.get('version', '?')
        print(f"  {marker} {name:20} (v{version})")

    print()

def switch_profile():
    """Cambia el perfil activo"""
    profiles = list_profiles()
    if not profiles:
        print(color("No hay perfiles disponibles.", Colors.RED))
        return

    if is_server_running():
        print(color("Deten el servidor antes de cambiar de perfil.", Colors.YELLOW))
        return

    print("\nPerfiles disponibles:")
    for i, name in enumerate(profiles, 1):
        profile = load_profile(name)
        print(f"  [{i}] {name} (v{profile.get('version', '?')})")

    try:
        choice = input("\nElige perfil (numero): ").strip()
        idx = int(choice) - 1
        if 0 <= idx < len(profiles):
            set_active_profile(profiles[idx])
            print(color(f"\nPerfil activo: {profiles[idx]}", Colors.GREEN))
        else:
            print(color("Opcion invalida.", Colors.RED))
    except (ValueError, KeyboardInterrupt):
        print("\nCancelado.")

def create_profile():
    """Crea un nuevo perfil"""
    print(f"\n{color('=== Crear nuevo perfil ===', Colors.BOLD)}\n")

    # Nombre
    name = input("Nombre del perfil: ").strip().lower().replace(" ", "_")
    if not name:
        print(color("Nombre invalido.", Colors.RED))
        return

    if (PROFILES_DIR / name).exists():
        print(color("Ya existe un perfil con ese nombre.", Colors.RED))
        return

    # Version
    print("\nVersiones disponibles:")
    versions = get_available_versions()
    for i, v in enumerate(versions[:10], 1):
        print(f"  [{i}] {v}")

    try:
        choice = input("\nElige version (numero o escribe version): ").strip()
        if choice.isdigit():
            idx = int(choice) - 1
            version = versions[idx] if 0 <= idx < len(versions) else versions[0]
        else:
            version = choice
    except:
        version = versions[0]

    print(f"\nCreando perfil '{name}' con Minecraft {version}...")

    # Crear directorio
    profile_dir = PROFILES_DIR / name
    profile_dir.mkdir(parents=True)
    (profile_dir / "mods").mkdir()

    # Descargar Fabric
    print("Descargando Fabric...")
    jar_file = download_fabric(version, profile_dir)

    if not jar_file:
        print(color("Error descargando Fabric.", Colors.RED))
        shutil.rmtree(profile_dir)
        return

    # Crear EULA
    (profile_dir / "eula.txt").write_text("eula=true\n")

    # Crear server.properties
    create_server_properties(profile_dir)

    # Guardar perfil
    profile_data = {
        "name": name,
        "version": version,
        "loader": "fabric",
        "jar_file": jar_file,
        "ram_min": "2G",
        "ram_max": "5G",
        "created": datetime.now().strftime("%Y-%m-%d")
    }
    save_profile(name, profile_data)

    # Preguntar si descargar mods basicos
    if input("\nDescargar mods recomendados (Lithium, Fabric API)? [S/n]: ").lower() != 'n':
        download_essential_mods(version, profile_dir / "mods")

    set_active_profile(name)
    print(color(f"\nPerfil '{name}' creado y activado!", Colors.GREEN))

def delete_profile():
    """Elimina un perfil"""
    profiles = list_profiles()
    active = get_active_profile()

    print("\nPerfiles disponibles:")
    for i, name in enumerate(profiles, 1):
        marker = "(activo)" if name == active else ""
        print(f"  [{i}] {name} {marker}")

    try:
        choice = input("\nPerfil a eliminar (numero): ").strip()
        idx = int(choice) - 1
        if 0 <= idx < len(profiles):
            name = profiles[idx]
            if is_server_running() and name == active:
                print(color("Deten el servidor antes de eliminar el perfil activo.", Colors.RED))
                return

            confirm = input(f"Eliminar '{name}' y todo su contenido? [s/N]: ").lower()
            if confirm == 's':
                shutil.rmtree(PROFILES_DIR / name)
                print(color(f"Perfil '{name}' eliminado.", Colors.GREEN))
                if name == active:
                    remaining = list_profiles()
                    if remaining:
                        set_active_profile(remaining[0])
            else:
                print("Cancelado.")
        else:
            print(color("Opcion invalida.", Colors.RED))
    except (ValueError, KeyboardInterrupt):
        print("\nCancelado.")

# ============ MODS ============

def manage_mods():
    """Menu de gestion de mods"""
    profile_name = get_active_profile()
    if not profile_name:
        print(color("No hay perfil activo.", Colors.RED))
        return

    profile = load_profile(profile_name)
    mods_dir = get_profile_dir(profile_name) / "mods"

    while True:
        clear()
        version = profile.get('version', '?')
        print(f"\n{color(f'=== Mods: {profile_name} (v{version}) ===', Colors.BOLD)}\n")

        # Listar mods
        mods = list(mods_dir.glob("*.jar"))
        disabled_dir = mods_dir / ".disabled"
        disabled = list(disabled_dir.glob("*.jar")) if disabled_dir.exists() else []

        print("  Activos:")
        if mods:
            for m in mods:
                print(f"    {color('+', Colors.GREEN)} {m.name}")
        else:
            print("    (ninguno)")

        if disabled:
            print("\n  Desactivados:")
            for m in disabled:
                print(f"    {color('-', Colors.RED)} {m.name}")

        print(f"\n  [1] Buscar e instalar mod")
        print(f"  [2] Desactivar mod")
        print(f"  [3] Activar mod")
        print(f"  [4] Eliminar mod")
        print(f"  [0] Volver")

        choice = input("\nOpcion: ").strip()

        if choice == '1':
            search_and_install_mod(profile['version'], mods_dir)
        elif choice == '2':
            disable_mod(mods_dir)
        elif choice == '3':
            enable_mod(mods_dir)
        elif choice == '4':
            remove_mod(mods_dir)
        elif choice == '0':
            break

def search_and_install_mod(version, mods_dir):
    """Busca e instala un mod desde Modrinth"""
    query = input("\nBuscar mod: ").strip()
    if not query:
        return

    print(f"\nBuscando '{query}'...")

    try:
        url = f"https://api.modrinth.com/v2/search?query={urllib.parse.quote(query)}&facets=[[\"versions:{version}\"],[\"categories:fabric\"]]&limit=10"
        with urllib.request.urlopen(url, timeout=10) as response:
            data = json.loads(response.read())

        hits = data.get('hits', [])
        if not hits:
            print(color("No se encontraron mods.", Colors.YELLOW))
            input("\nEnter para continuar...")
            return

        print("\nResultados:")
        for i, hit in enumerate(hits, 1):
            print(f"  [{i}] {hit['title']}")
            print(f"      {hit.get('description', '')[:60]}...")

        choice = input("\nInstalar (numero): ").strip()
        if not choice.isdigit():
            return

        idx = int(choice) - 1
        if 0 <= idx < len(hits):
            mod = hits[idx]
            install_mod_from_modrinth(mod['project_id'], version, mods_dir)

    except Exception as e:
        print(color(f"Error: {e}", Colors.RED))
        input("\nEnter para continuar...")

def install_mod_from_modrinth(project_id, version, mods_dir):
    """Descarga e instala un mod desde Modrinth"""
    try:
        url = f"https://api.modrinth.com/v2/project/{project_id}/version?game_versions=%5B%22{version}%22%5D&loaders=%5B%22fabric%22%5D"
        with urllib.request.urlopen(url, timeout=10) as response:
            versions = json.loads(response.read())

        if not versions:
            print(color("No hay version compatible.", Colors.RED))
            return

        latest = versions[0]
        file_info = latest['files'][0]
        file_url = file_info['url']
        file_name = file_info['filename']

        print(f"Descargando {file_name}...")

        dest = mods_dir / file_name
        urllib.request.urlretrieve(file_url, dest)

        print(color(f"Instalado: {file_name}", Colors.GREEN))

    except Exception as e:
        print(color(f"Error: {e}", Colors.RED))

    input("\nEnter para continuar...")

def disable_mod(mods_dir):
    """Desactiva un mod"""
    mods = list(mods_dir.glob("*.jar"))
    if not mods:
        print("No hay mods activos.")
        input("\nEnter para continuar...")
        return

    print("\nMods activos:")
    for i, m in enumerate(mods, 1):
        print(f"  [{i}] {m.name}")

    choice = input("\nDesactivar (numero): ").strip()
    if choice.isdigit():
        idx = int(choice) - 1
        if 0 <= idx < len(mods):
            disabled_dir = mods_dir / ".disabled"
            disabled_dir.mkdir(exist_ok=True)
            mods[idx].rename(disabled_dir / mods[idx].name)
            print(color("Mod desactivado.", Colors.GREEN))

    input("\nEnter para continuar...")

def enable_mod(mods_dir):
    """Activa un mod desactivado"""
    disabled_dir = mods_dir / ".disabled"
    if not disabled_dir.exists():
        print("No hay mods desactivados.")
        input("\nEnter para continuar...")
        return

    mods = list(disabled_dir.glob("*.jar"))
    if not mods:
        print("No hay mods desactivados.")
        input("\nEnter para continuar...")
        return

    print("\nMods desactivados:")
    for i, m in enumerate(mods, 1):
        print(f"  [{i}] {m.name}")

    choice = input("\nActivar (numero): ").strip()
    if choice.isdigit():
        idx = int(choice) - 1
        if 0 <= idx < len(mods):
            mods[idx].rename(mods_dir / mods[idx].name)
            print(color("Mod activado.", Colors.GREEN))

    input("\nEnter para continuar...")

def remove_mod(mods_dir):
    """Elimina un mod"""
    all_mods = list(mods_dir.glob("*.jar"))
    disabled_dir = mods_dir / ".disabled"
    if disabled_dir.exists():
        all_mods.extend(disabled_dir.glob("*.jar"))

    if not all_mods:
        print("No hay mods.")
        input("\nEnter para continuar...")
        return

    print("\nTodos los mods:")
    for i, m in enumerate(all_mods, 1):
        status = "(desactivado)" if ".disabled" in str(m) else ""
        print(f"  [{i}] {m.name} {status}")

    choice = input("\nEliminar (numero): ").strip()
    if choice.isdigit():
        idx = int(choice) - 1
        if 0 <= idx < len(all_mods):
            confirm = input(f"Eliminar '{all_mods[idx].name}'? [s/N]: ").lower()
            if confirm == 's':
                all_mods[idx].unlink()
                print(color("Mod eliminado.", Colors.GREEN))

    input("\nEnter para continuar...")

# ============ DESCARGAS ============

def get_available_versions():
    """Obtiene versiones de Minecraft disponibles"""
    try:
        url = "https://meta.fabricmc.net/v2/versions/game"
        with urllib.request.urlopen(url, timeout=10) as response:
            data = json.loads(response.read())
        return [v['version'] for v in data if v.get('stable', False)][:20]
    except:
        return ["1.21.4", "1.21.3", "1.21.1", "1.21", "1.20.6", "1.20.4", "1.20.2", "1.20.1", "1.19.4", "1.19.2"]

def download_fabric(version, profile_dir):
    """Descarga el servidor Fabric para una version"""
    try:
        # Obtener ultima version del loader
        url = "https://meta.fabricmc.net/v2/versions/loader"
        with urllib.request.urlopen(url, timeout=10) as response:
            loaders = json.loads(response.read())
        loader_version = loaders[0]['version']

        # Descargar servidor
        jar_name = f"fabric-server-mc.{version}-loader.{loader_version}-launcher.1.0.1.jar"
        jar_url = f"https://meta.fabricmc.net/v2/versions/loader/{version}/{loader_version}/1.0.1/server/jar"

        dest = profile_dir / jar_name
        urllib.request.urlretrieve(jar_url, dest)

        print(color(f"Fabric {version} descargado.", Colors.GREEN))
        return jar_name

    except Exception as e:
        print(color(f"Error: {e}", Colors.RED))
        return None

def download_essential_mods(version, mods_dir):
    """Descarga mods esenciales"""
    mods = [
        ("gvQqBUqZ", "Lithium"),      # Optimizacion
        ("P7dR8mSH", "Fabric API"),   # API base
    ]

    for project_id, name in mods:
        try:
            print(f"Descargando {name}...")
            url = f"https://api.modrinth.com/v2/project/{project_id}/version?game_versions=%5B%22{version}%22%5D&loaders=%5B%22fabric%22%5D"
            with urllib.request.urlopen(url, timeout=10) as response:
                versions = json.loads(response.read())

            if versions:
                file_info = versions[0]['files'][0]
                urllib.request.urlretrieve(file_info['url'], mods_dir / file_info['filename'])
                print(color(f"  {name} instalado.", Colors.GREEN))
        except Exception as e:
            print(color(f"  Error con {name}: {e}", Colors.YELLOW))

def create_server_properties(profile_dir):
    """Crea server.properties por defecto"""
    props = """#Minecraft server properties
enable-jmx-monitoring=false
rcon.port=25575
level-seed=
gamemode=survival
enable-command-block=false
enable-query=false
generator-settings={}
enforce-secure-profile=true
level-name=world
motd=Minecraft Server
query.port=25565
pvp=true
generate-structures=true
max-chained-neighbor-updates=1000000
difficulty=hard
network-compression-threshold=256
max-tick-time=60000
require-resource-pack=false
use-native-transport=true
max-players=20
online-mode=true
enable-status=true
allow-flight=false
initial-disabled-packs=
broadcast-rcon-to-ops=true
view-distance=10
server-ip=
resource-pack-prompt=
allow-nether=true
server-port=25565
enable-rcon=false
sync-chunk-writes=true
op-permission-level=4
prevent-proxy-connections=false
hide-online-players=false
resource-pack=
entity-broadcast-range-percentage=100
simulation-distance=10
rcon.password=
player-idle-timeout=0
force-gamemode=false
rate-limit=0
hardcore=false
white-list=false
broadcast-console-to-ops=true
spawn-npcs=true
spawn-animals=true
function-permission-level=2
initial-enabled-packs=vanilla
level-type=minecraft\\:normal
text-filtering-config=
spawn-monsters=true
enforce-whitelist=false
spawn-protection=16
resource-pack-sha1=
max-world-size=29999984
"""
    (profile_dir / "server.properties").write_text(props)

# ============ LOGS ============

def show_logs():
    """Muestra los logs del servidor"""
    profile_name = get_active_profile()
    if not profile_name:
        print(color("No hay perfil activo.", Colors.RED))
        return

    log_file = get_profile_dir(profile_name) / "logs" / "latest.log"

    if not log_file.exists():
        print(color("No hay logs todavia.", Colors.YELLOW))
        return

    print(color(f"Mostrando logs de '{profile_name}' (Ctrl+C para salir)\n", Colors.CYAN))
    try:
        subprocess.run(['tail', '-f', str(log_file)])
    except KeyboardInterrupt:
        print()

# ============ MENU PRINCIPAL ============

def show_menu():
    """Muestra el menu principal"""
    clear()

    profile = get_active_profile()
    running = is_server_running()

    print(f"""
{color('╔════════════════════════════════════════╗', Colors.CYAN)}
{color('║', Colors.CYAN)}   {color('Minecraft Server Manager', Colors.BOLD)}          {color('║', Colors.CYAN)}
{color('╚════════════════════════════════════════╝', Colors.CYAN)}
""")

    # Estado
    if profile:
        profile_data = load_profile(profile)
        version = profile_data.get('version', '?') if profile_data else '?'
        status = color("ONLINE", Colors.GREEN) if running else color("OFFLINE", Colors.RED)
        print(f"  Perfil: {color(profile, Colors.CYAN)} (v{version})  [{status}]")
    else:
        print(f"  {color('No hay perfil activo', Colors.YELLOW)}")

    print(f"""
  {color('[1]', Colors.BOLD)} {'Detener' if running else 'Iniciar'} servidor
  {color('[2]', Colors.BOLD)} Consola
  {color('[3]', Colors.BOLD)} Logs
  {color('[4]', Colors.BOLD)} Ver perfiles
  {color('[5]', Colors.BOLD)} Cambiar perfil
  {color('[6]', Colors.BOLD)} Crear perfil
  {color('[7]', Colors.BOLD)} Eliminar perfil
  {color('[8]', Colors.BOLD)} Gestionar mods
  {color('[0]', Colors.BOLD)} Salir
""")

def main_menu():
    """Loop del menu principal"""
    while True:
        show_menu()
        choice = input("  Opcion: ").strip()

        if choice == '1':
            if is_server_running():
                stop_server()
            else:
                start_server()
            input("\nEnter para continuar...")
        elif choice == '2':
            server_console()
        elif choice == '3':
            show_logs()
        elif choice == '4':
            show_profiles()
            input("\nEnter para continuar...")
        elif choice == '5':
            switch_profile()
            input("\nEnter para continuar...")
        elif choice == '6':
            create_profile()
            input("\nEnter para continuar...")
        elif choice == '7':
            delete_profile()
            input("\nEnter para continuar...")
        elif choice == '8':
            manage_mods()
        elif choice == '0':
            print("\nHasta luego!")
            sys.exit(0)

def main():
    """Punto de entrada principal"""
    # Crear directorios si no existen
    PROFILES_DIR.mkdir(parents=True, exist_ok=True)

    # Comandos directos
    if len(sys.argv) > 1:
        cmd = sys.argv[1].lower()

        if cmd == 'start':
            start_server()
        elif cmd == 'stop':
            stop_server()
        elif cmd == 'restart':
            stop_server()
            import time
            time.sleep(3)
            start_server()
        elif cmd == 'console':
            server_console()
        elif cmd == 'logs':
            show_logs()
        elif cmd == 'status':
            server_status()
        elif cmd == 'profiles':
            show_profiles()
        elif cmd == 'new':
            create_profile()
        elif cmd == 'mods':
            manage_mods()
        elif cmd == 'help':
            print("""
Uso: mc [comando]

Comandos:
  start     Iniciar servidor
  stop      Detener servidor
  restart   Reiniciar servidor
  console   Abrir consola
  logs      Ver logs
  status    Ver estado
  profiles  Listar perfiles
  new       Crear perfil
  mods      Gestionar mods
  help      Mostrar ayuda

Sin argumentos abre el menu interactivo.
""")
        else:
            print(f"Comando desconocido: {cmd}")
            print("Usa 'mc help' para ver comandos disponibles.")
    else:
        # Menu interactivo
        try:
            main_menu()
        except KeyboardInterrupt:
            print("\n\nHasta luego!")
            sys.exit(0)

if __name__ == "__main__":
    main()
MCSCRIPT

# Hacer ejecutable
chmod +x /opt/minecraft/mc

# Crear enlace simbolico
ln -sf /opt/minecraft/mc /usr/local/bin/mc

echo ""
echo -e "${GREEN}╔═══════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}║   Instalacion completada!                     ║${NC}"
echo -e "${GREEN}╚═══════════════════════════════════════════════╝${NC}"
echo ""
echo -e "  Directorio: ${CYAN}/opt/minecraft${NC}"
echo ""
echo -e "  ${YELLOW}Para empezar:${NC}"
echo -e "    cd /opt/minecraft"
echo -e "    ./mc"
echo ""
echo -e "  ${YELLOW}O desde cualquier lugar:${NC}"
echo -e "    mc"
echo ""
