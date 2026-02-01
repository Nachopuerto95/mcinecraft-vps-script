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

echo -e "${YELLOW}[1/5] Actualizando repositorios...${NC}"
$PKG_UPDATE > /dev/null 2>&1

echo -e "${YELLOW}[2/5] Instalando dependencias (Java 17, screen, ufw)...${NC}"
if [ "$PKG_MANAGER" = "apt" ]; then
    $PKG_INSTALL openjdk-17-jre-headless screen ufw > /dev/null 2>&1
else
    $PKG_INSTALL java-17-openjdk-headless screen > /dev/null 2>&1
    # En RHEL/CentOS usar firewalld en vez de ufw
    $PKG_INSTALL firewalld > /dev/null 2>&1
fi

echo -e "${YELLOW}[3/5] Configurando firewall (puerto 25565 + SSH)...${NC}"
if command -v ufw > /dev/null 2>&1; then
    ufw allow OpenSSH > /dev/null 2>&1
    ufw allow 25565/tcp > /dev/null 2>&1
    echo "y" | ufw enable > /dev/null 2>&1
    echo -e "  ${GREEN}ufw activado: SSH + Minecraft (25565/tcp)${NC}"
elif command -v firewall-cmd > /dev/null 2>&1; then
    systemctl enable --now firewalld > /dev/null 2>&1
    firewall-cmd --permanent --add-service=ssh > /dev/null 2>&1
    firewall-cmd --permanent --add-port=25565/tcp > /dev/null 2>&1
    firewall-cmd --reload > /dev/null 2>&1
    echo -e "  ${GREEN}firewalld activado: SSH + Minecraft (25565/tcp)${NC}"
fi

echo -e "${YELLOW}[4/5] Creando directorio /opt/minecraft...${NC}"
mkdir -p /opt/minecraft/profiles

echo -e "${YELLOW}[5/5] Instalando Minecraft Server Manager...${NC}"

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
import zipfile
import hashlib
import platform
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
    loader = profile.get('loader', 'fabric')

    # Comando de inicio
    jvm_opts = f"-Xms{ram_min} -Xmx{ram_max} " \
        "-XX:+UseG1GC -XX:+ParallelRefProcEnabled -XX:MaxGCPauseMillis=200 " \
        "-XX:+UnlockExperimentalVMOptions -XX:+DisableExplicitGC " \
        "-XX:G1NewSizePercent=30 -XX:G1MaxNewSizePercent=40 " \
        "-XX:G1HeapRegionSize=8M -XX:G1ReservePercent=20"

    if loader == 'forge':
        # Forge usa run.sh + user_jvm_args.txt
        jvm_file = profile_dir / "user_jvm_args.txt"
        jvm_file.write_text("\n".join(jvm_opts.split()) + "\n")
        java_cmd = f"cd {profile_dir} && bash run.sh nogui"
    else:
        java_cmd = f"cd {profile_dir} && java {jvm_opts} -jar {jar_file} nogui"

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
    print(f"  Version: {profile['version']} ({loader.capitalize()})")
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
        loader = profile.get('loader', 'fabric').capitalize()
        print(f"  {marker} {name:20} (v{version} - {loader})")

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
        ldr = profile.get('loader', 'fabric').capitalize()
        print(f"  [{i}] {name} (v{profile.get('version', '?')} - {ldr})")

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

    # Loader
    print("\nElige mod loader:")
    print(f"  [1] Fabric (recomendado)")
    print(f"  [2] Forge")
    loader_choice = input("\nOpcion [1]: ").strip()
    loader = "forge" if loader_choice == "2" else "fabric"

    # Version
    print(f"\nVersiones disponibles ({loader.capitalize()}):")
    versions = get_available_versions(loader)
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

    print(f"\nCreando perfil '{name}' con Minecraft {version} ({loader.capitalize()})...")

    # Crear directorio
    profile_dir = PROFILES_DIR / name
    profile_dir.mkdir(parents=True)
    (profile_dir / "mods").mkdir()

    # Descargar loader
    print(f"Descargando {loader.capitalize()}...")
    if loader == "forge":
        jar_file = download_forge(version, profile_dir)
    else:
        jar_file = download_fabric(version, profile_dir)

    if not jar_file:
        print(color(f"Error descargando {loader.capitalize()}.", Colors.RED))
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
        "loader": loader,
        "jar_file": jar_file,
        "ram_min": "2G",
        "ram_max": "5G",
        "created": datetime.now().strftime("%Y-%m-%d")
    }
    save_profile(name, profile_data)

    # Preguntar si descargar mods basicos
    if input("\nDescargar mods recomendados? [S/n]: ").lower() != 'n':
        download_essential_mods(version, profile_dir / "mods", loader)

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

def mods_menu():
    """Submenu de mods"""
    profile_name = get_active_profile()
    if not profile_name:
        print(color("No hay perfil activo.", Colors.RED))
        input("\nEnter para continuar...")
        return

    profile = load_profile(profile_name)

    while True:
        clear()
        version = profile.get('version', '?')
        print(f"\n{color(f'=== Mods: {profile_name} (v{version}) ===', Colors.BOLD)}\n")

        print(f"  {color('[1]', Colors.BOLD)} Mods (navegador interactivo)")
        print(f"  {color('[2]', Colors.BOLD)} Buscar e instalar mod")
        print(f"  {color('[3]', Colors.BOLD)} Importar .mrpack")
        print(f"  {color('[4]', Colors.BOLD)} Sincronizacion jugadores (packwiz)")
        print(f"  {color('[0]', Colors.BOLD)} Volver")

        choice = input("\n  Opcion: ").strip()

        if choice == '1':
            interactive_mod_browser(profile_name)
        elif choice == '2':
            mods_dir = get_profile_dir(profile_name) / "mods"
            search_and_install_mod(profile['version'], mods_dir, profile.get('loader', 'fabric'), profile_name)
        elif choice == '3':
            import_mrpack(profile_name)
        elif choice == '4':
            packwiz_menu(profile_name)
        elif choice == '0':
            break

def search_and_install_mod(version, mods_dir, loader="fabric", profile_name=None):
    """Busca e instala un mod desde Modrinth"""
    query = input("\nBuscar mod: ").strip()
    if not query:
        return

    print(f"\nBuscando '{query}' para {loader.capitalize()}...")

    try:
        url = f"https://api.modrinth.com/v2/search?query={urllib.parse.quote(query)}&facets=[[\"versions:{version}\"],[\"categories:{loader}\"]]&limit=10"
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
            install_mod_from_modrinth(mod['project_id'], version, mods_dir, loader, profile_name)

    except Exception as e:
        print(color(f"Error: {e}", Colors.RED))
        input("\nEnter para continuar...")

def install_mod_from_modrinth(project_id, version, mods_dir, loader="fabric", profile_name=None):
    """Descarga e instala un mod desde Modrinth"""
    try:
        url = f"https://api.modrinth.com/v2/project/{project_id}/version?game_versions=%5B%22{version}%22%5D&loaders=%5B%22{loader}%22%5D"
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
        packwiz_refresh_if_enabled(profile_name)

    except Exception as e:
        print(color(f"Error: {e}", Colors.RED))

    input("\nEnter para continuar...")

def disable_mod(mods_dir, profile_name=None):
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
            packwiz_refresh_if_enabled(profile_name)

    input("\nEnter para continuar...")

def enable_mod(mods_dir, profile_name=None):
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
            packwiz_refresh_if_enabled(profile_name)

    input("\nEnter para continuar...")

def remove_mod(mods_dir, profile_name=None):
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
                packwiz_refresh_if_enabled(profile_name)

    input("\nEnter para continuar...")

# ============ NAVEGADOR INTERACTIVO DE MODS ============

def interactive_mod_browser(profile_name):
    """Navegador interactivo de mods con curses"""
    try:
        import curses
        curses.wrapper(lambda stdscr: _mod_browser_inner(stdscr, profile_name))
    except Exception as e:
        # Fallback a modo texto si curses no funciona
        print(color(f"Curses no disponible ({e}), usando modo texto...", Colors.YELLOW))
        _mod_browser_text_fallback(profile_name)

def _mod_browser_text_fallback(profile_name):
    """Fallback de texto para el navegador de mods"""
    mods_dir = get_profile_dir(profile_name) / "mods"

    while True:
        clear()
        print(f"\n{color(f'=== Mods: {profile_name} ===', Colors.BOLD)}\n")

        active_mods = sorted(mods_dir.glob("*.jar"), key=lambda x: x.name.lower())
        disabled_dir = mods_dir / ".disabled"
        disabled_mods = sorted(disabled_dir.glob("*.jar"), key=lambda x: x.name.lower()) if disabled_dir.exists() else []

        print("  ACTIVOS:")
        if active_mods:
            for i, m in enumerate(active_mods, 1):
                print(f"    [{i}] {color('+', Colors.GREEN)} {m.stem}")
        else:
            print("    (ninguno)")

        print("\n  DESACTIVADOS:")
        if disabled_mods:
            for i, m in enumerate(disabled_mods, len(active_mods) + 1):
                print(f"    [{i}] {color('-', Colors.RED)} {m.stem}")
        else:
            print("    (ninguno)")

        print(f"\n  [d] Desactivar mod  [a] Activar mod  [x] Eliminar mod  [q] Volver")

        choice = input("\n  Opcion: ").strip().lower()

        if choice == 'q':
            break
        elif choice == 'd':
            disable_mod(mods_dir, profile_name)
        elif choice == 'a':
            enable_mod(mods_dir, profile_name)
        elif choice == 'x':
            remove_mod(mods_dir, profile_name)

def _mod_browser_inner(stdscr, profile_name):
    """Navegador de mods con curses"""
    import curses

    curses.curs_set(0)
    stdscr.keypad(True)

    # Colores
    curses.start_color()
    curses.use_default_colors()
    curses.init_pair(1, curses.COLOR_GREEN, -1)
    curses.init_pair(2, curses.COLOR_RED, -1)
    curses.init_pair(3, curses.COLOR_CYAN, -1)
    curses.init_pair(4, curses.COLOR_YELLOW, -1)

    mods_dir = get_profile_dir(profile_name) / "mods"
    disabled_dir = mods_dir / ".disabled"

    current_panel = 0  # 0 = activos, 1 = desactivados
    current_idx = 0
    message = ""

    while True:
        stdscr.clear()
        height, width = stdscr.getmaxyx()

        # Cargar mods
        active_mods = sorted(mods_dir.glob("*.jar"), key=lambda x: x.name.lower())
        disabled_mods = sorted(disabled_dir.glob("*.jar"), key=lambda x: x.name.lower()) if disabled_dir.exists() else []

        # Titulo
        title = f" Mods: {profile_name} "
        stdscr.addstr(0, (width - len(title)) // 2, title, curses.A_BOLD | curses.color_pair(3))

        # Calcular anchos de panel
        panel_width = (width - 3) // 2

        # Panel izquierdo - Activos
        header_active = " ACTIVOS "
        attr_active = curses.A_BOLD | curses.A_REVERSE if current_panel == 0 else curses.A_BOLD
        stdscr.addstr(2, 1, header_active.center(panel_width), attr_active | curses.color_pair(1))

        # Panel derecho - Desactivados
        header_disabled = " DESACTIVADOS "
        attr_disabled = curses.A_BOLD | curses.A_REVERSE if current_panel == 1 else curses.A_BOLD
        stdscr.addstr(2, panel_width + 2, header_disabled.center(panel_width), attr_disabled | curses.color_pair(2))

        # Contenido paneles
        max_items = height - 7

        # Panel activos
        for i, mod in enumerate(active_mods[:max_items]):
            y = 4 + i
            name = mod.stem[:panel_width - 4]
            if current_panel == 0 and i == current_idx:
                stdscr.addstr(y, 1, f" > {name}".ljust(panel_width), curses.A_REVERSE)
            else:
                stdscr.addstr(y, 1, f"   {name}".ljust(panel_width), curses.color_pair(1))

        if not active_mods:
            stdscr.addstr(4, 1, "   (ninguno)".ljust(panel_width))

        # Panel desactivados
        for i, mod in enumerate(disabled_mods[:max_items]):
            y = 4 + i
            name = mod.stem[:panel_width - 4]
            if current_panel == 1 and i == current_idx:
                stdscr.addstr(y, panel_width + 2, f" > {name}".ljust(panel_width), curses.A_REVERSE)
            else:
                stdscr.addstr(y, panel_width + 2, f"   {name}".ljust(panel_width), curses.color_pair(2))

        if not disabled_mods:
            stdscr.addstr(4, panel_width + 2, "   (ninguno)".ljust(panel_width))

        # Mensaje
        if message:
            stdscr.addstr(height - 3, 1, message[:width-2], curses.color_pair(4))

        # Ayuda
        help_text = " ←/→: Panel | ↑/↓: Navegar | Enter: Acciones | q: Salir "
        stdscr.addstr(height - 1, (width - len(help_text)) // 2, help_text, curses.A_DIM)

        stdscr.refresh()

        # Input
        key = stdscr.getch()
        message = ""

        if key == ord('q') or key == 27:  # q o ESC
            break
        elif key == curses.KEY_LEFT:
            current_panel = 0
            current_idx = 0
        elif key == curses.KEY_RIGHT:
            current_panel = 1
            current_idx = 0
        elif key == curses.KEY_UP:
            current_idx = max(0, current_idx - 1)
        elif key == curses.KEY_DOWN:
            mods_list = active_mods if current_panel == 0 else disabled_mods
            current_idx = min(len(mods_list) - 1, current_idx + 1) if mods_list else 0
        elif key == ord('\n') or key == curses.KEY_ENTER or key == 10:
            mods_list = active_mods if current_panel == 0 else disabled_mods
            if mods_list and 0 <= current_idx < len(mods_list):
                action = _show_mod_actions(stdscr, mods_list[current_idx], current_panel == 0)
                if action == 'toggle':
                    mod = mods_list[current_idx]
                    if current_panel == 0:
                        disabled_dir.mkdir(exist_ok=True)
                        mod.rename(disabled_dir / mod.name)
                        message = f"Desactivado: {mod.stem}"
                    else:
                        mod.rename(mods_dir / mod.name)
                        message = f"Activado: {mod.stem}"
                    packwiz_refresh_if_enabled(profile_name)
                    current_idx = max(0, current_idx - 1)
                elif action == 'delete':
                    mod = mods_list[current_idx]
                    mod.unlink()
                    message = f"Eliminado: {mod.stem}"
                    packwiz_refresh_if_enabled(profile_name)
                    current_idx = max(0, current_idx - 1)

def _show_mod_actions(stdscr, mod_path, is_active):
    """Muestra menu de acciones para un mod"""
    import curses

    height, width = stdscr.getmaxyx()

    # Ventana de dialogo
    dialog_h, dialog_w = 8, 40
    start_y = (height - dialog_h) // 2
    start_x = (width - dialog_w) // 2

    win = curses.newwin(dialog_h, dialog_w, start_y, start_x)
    win.box()

    mod_name = mod_path.stem[:dialog_w - 6]
    win.addstr(1, 2, mod_name, curses.A_BOLD)
    win.addstr(2, 2, "-" * (dialog_w - 4))

    toggle_text = "Desactivar" if is_active else "Activar"
    win.addstr(4, 4, f"[1] {toggle_text}")
    win.addstr(5, 4, "[2] Eliminar")
    win.addstr(6, 4, "[0] Cancelar")

    win.refresh()

    while True:
        key = win.getch()
        if key == ord('1'):
            return 'toggle'
        elif key == ord('2'):
            return 'delete'
        elif key == ord('0') or key == 27:
            return None

# ============ IMPORTAR MRPACK ============

def import_mrpack(profile_name=None, mrpack_path_str=None):
    """Importa un modpack desde archivo .mrpack"""
    if not profile_name:
        profile_name = get_active_profile()

    if not profile_name:
        print(color("No hay perfil activo.", Colors.RED))
        input("\nEnter para continuar...")
        return False

    profile_dir = get_profile_dir(profile_name)
    mods_dir = profile_dir / "mods"

    # Obtener ruta del archivo
    if not mrpack_path_str:
        mrpack_path_str = input("\nRuta al archivo .mrpack: ").strip()

    if not mrpack_path_str:
        print(color("Ruta vacia.", Colors.RED))
        input("\nEnter para continuar...")
        return False

    mrpack_path = Path(mrpack_path_str).expanduser()

    if not mrpack_path.exists():
        print(color(f"Archivo no encontrado: {mrpack_path}", Colors.RED))
        input("\nEnter para continuar...")
        return False

    print(f"\nImportando {mrpack_path.name}...")

    try:
        with zipfile.ZipFile(mrpack_path, 'r') as zf:
            # Leer index
            try:
                index_data = json.loads(zf.read('modrinth.index.json'))
            except KeyError:
                print(color("Archivo .mrpack invalido (falta modrinth.index.json)", Colors.RED))
                input("\nEnter para continuar...")
                return False

            pack_name = index_data.get('name', 'Unknown')
            pack_version = index_data.get('versionId', '?')
            files = index_data.get('files', [])

            print(f"  Pack: {pack_name} v{pack_version}")
            print(f"  Mods: {len(files)}")

            # Descargar mods
            success_count = 0
            for i, file_info in enumerate(files, 1):
                file_path = file_info.get('path', '')
                downloads = file_info.get('downloads', [])
                hashes = file_info.get('hashes', {})
                expected_hash = hashes.get('sha512', '')

                # Solo mods (ignorar client-side)
                env = file_info.get('env', {})
                if env.get('server') == 'unsupported':
                    continue

                if not downloads:
                    continue

                file_name = Path(file_path).name
                dest_path = mods_dir / file_name

                print(f"  [{i}/{len(files)}] {file_name}...", end=" ", flush=True)

                try:
                    # Descargar
                    urllib.request.urlretrieve(downloads[0], dest_path)

                    # Verificar hash
                    if expected_hash:
                        actual_hash = hashlib.sha512(dest_path.read_bytes()).hexdigest()
                        if actual_hash != expected_hash:
                            print(color("HASH INVALIDO", Colors.RED))
                            dest_path.unlink()
                            continue

                    print(color("OK", Colors.GREEN))
                    success_count += 1

                except Exception as e:
                    print(color(f"ERROR: {e}", Colors.RED))

            # Extraer overrides (configs, etc)
            overrides_extracted = 0
            for name in zf.namelist():
                # Solo server-overrides y overrides, ignorar client-overrides
                if name.startswith('client-overrides/'):
                    continue

                if name.startswith('overrides/') or name.startswith('server-overrides/'):
                    # Determinar prefijo a remover
                    if name.startswith('server-overrides/'):
                        prefix = 'server-overrides/'
                    else:
                        prefix = 'overrides/'

                    relative_path = name[len(prefix):]
                    if not relative_path:
                        continue

                    dest = profile_dir / relative_path

                    if name.endswith('/'):
                        dest.mkdir(parents=True, exist_ok=True)
                    else:
                        dest.parent.mkdir(parents=True, exist_ok=True)
                        dest.write_bytes(zf.read(name))
                        overrides_extracted += 1

            print(f"\n  Mods instalados: {success_count}/{len(files)}")
            if overrides_extracted:
                print(f"  Archivos de config extraidos: {overrides_extracted}")

            print(color("\nModpack importado correctamente!", Colors.GREEN))
            packwiz_refresh_if_enabled(profile_name)

    except zipfile.BadZipFile:
        print(color("Archivo .mrpack corrupto o invalido.", Colors.RED))
        input("\nEnter para continuar...")
        return False
    except Exception as e:
        print(color(f"Error importando modpack: {e}", Colors.RED))
        input("\nEnter para continuar...")
        return False

    input("\nEnter para continuar...")
    return True

# ============ PACKWIZ ============

PACKWIZ_SCREEN = "packwiz-http"
PACKWIZ_PORT = 8080

def packwiz_menu(profile_name):
    """Menu de packwiz"""
    while True:
        clear()
        print(f"\n{color('=== Packwiz (Sincronizacion jugadores) ===', Colors.BOLD)}\n")

        profile_dir = get_profile_dir(profile_name)
        pack_toml = profile_dir / "pack.toml"
        is_configured = pack_toml.exists()
        http_running = _packwiz_http_running()

        status = color("Configurado", Colors.GREEN) if is_configured else color("No configurado", Colors.YELLOW)
        http_status = color("Activo", Colors.GREEN) if http_running else color("Inactivo", Colors.RED)

        print(f"  Perfil: {profile_name}")
        print(f"  Estado: {status}")
        print(f"  Servidor HTTP: {http_status}")

        print(f"\n  {color('[1]', Colors.BOLD)} Configurar/Inicializar")
        print(f"  {color('[2]', Colors.BOLD)} Ver URL para jugadores")
        print(f"  {color('[3]', Colors.BOLD)} {'Detener' if http_running else 'Iniciar'} servidor HTTP")
        print(f"  {color('[4]', Colors.BOLD)} Refrescar manifiesto")
        print(f"  {color('[0]', Colors.BOLD)} Volver")

        choice = input("\n  Opcion: ").strip()

        if choice == '1':
            packwiz_init(profile_name)
            input("\nEnter para continuar...")
        elif choice == '2':
            packwiz_show_url(profile_name)
            input("\nEnter para continuar...")
        elif choice == '3':
            if http_running:
                packwiz_stop_server()
            else:
                packwiz_start_server(profile_name)
            input("\nEnter para continuar...")
        elif choice == '4':
            packwiz_refresh(profile_name)
            input("\nEnter para continuar...")
        elif choice == '0':
            break

def _packwiz_http_running():
    """Verifica si el servidor HTTP de packwiz esta corriendo"""
    result = subprocess.run(['screen', '-list'], capture_output=True, text=True)
    return PACKWIZ_SCREEN in result.stdout

def packwiz_ensure_binary():
    """Descarga packwiz si no existe"""
    packwiz_path = BASE_DIR / "packwiz"

    if packwiz_path.exists():
        return packwiz_path

    print("Descargando packwiz...")

    # Detectar arquitectura
    machine = platform.machine().lower()
    if machine in ('x86_64', 'amd64'):
        arch = 'amd64'
    elif machine in ('aarch64', 'arm64'):
        arch = 'arm64'
    elif machine.startswith('arm'):
        arch = 'arm'
    else:
        arch = '386'

    system = platform.system().lower()
    if system == 'darwin':
        system = 'darwin'
    else:
        system = 'linux'

    # URL de GitHub releases
    try:
        # Obtener ultima release
        api_url = "https://api.github.com/repos/packwiz/packwiz/releases/latest"
        req = urllib.request.Request(api_url, headers={'User-Agent': 'mc-manager'})
        with urllib.request.urlopen(req, timeout=10) as response:
            release = json.loads(response.read())

        # Buscar asset correcto
        asset_name = f"packwiz_{system}_{arch}"
        download_url = None

        for asset in release.get('assets', []):
            if asset['name'].startswith(asset_name):
                download_url = asset['browser_download_url']
                break

        if not download_url:
            print(color(f"No se encontro packwiz para {system}/{arch}", Colors.RED))
            return None

        urllib.request.urlretrieve(download_url, packwiz_path)
        packwiz_path.chmod(0o755)

        print(color("packwiz descargado.", Colors.GREEN))
        return packwiz_path

    except Exception as e:
        print(color(f"Error descargando packwiz: {e}", Colors.RED))
        return None

def packwiz_init(profile_name):
    """Inicializa packwiz en el perfil"""
    packwiz = packwiz_ensure_binary()
    if not packwiz:
        return False

    profile = load_profile(profile_name)
    profile_dir = get_profile_dir(profile_name)

    print(f"\nInicializando packwiz para '{profile_name}'...")

    # Ejecutar packwiz init
    result = subprocess.run(
        [str(packwiz), 'init', '--name', profile_name,
         '--mc-version', profile.get('version', '1.21.4'),
         '--modloader', profile.get('loader', 'fabric')],
        cwd=str(profile_dir),
        capture_output=True, text=True,
        input='\n'  # Acepta defaults
    )

    if result.returncode != 0:
        # Puede que ya exista, intentar refresh
        pass

    # Ejecutar refresh
    packwiz_refresh(profile_name)

    # Guardar config en perfil
    profile['packwiz_enabled'] = True
    save_profile(profile_name, profile)

    print(color("Packwiz configurado!", Colors.GREEN))
    return True

def packwiz_refresh(profile_name):
    """Refresca el manifiesto de packwiz"""
    packwiz = packwiz_ensure_binary()
    if not packwiz:
        return False

    profile_dir = get_profile_dir(profile_name)
    pack_toml = profile_dir / "pack.toml"

    if not pack_toml.exists():
        print(color("Packwiz no inicializado. Usa 'Configurar' primero.", Colors.YELLOW))
        return False

    print("Refrescando manifiesto...")

    result = subprocess.run(
        [str(packwiz), 'refresh'],
        cwd=str(profile_dir),
        capture_output=True, text=True
    )

    if result.returncode == 0:
        print(color("Manifiesto actualizado.", Colors.GREEN))
        return True
    else:
        print(color(f"Error: {result.stderr}", Colors.RED))
        return False

def packwiz_refresh_if_enabled(profile_name):
    """Refresca packwiz si esta habilitado para el perfil"""
    if not profile_name:
        return

    profile = load_profile(profile_name)
    if not profile:
        return

    if profile.get('packwiz_enabled'):
        profile_dir = get_profile_dir(profile_name)
        pack_toml = profile_dir / "pack.toml"

        if pack_toml.exists():
            packwiz = BASE_DIR / "packwiz"
            if packwiz.exists():
                subprocess.run(
                    [str(packwiz), 'refresh'],
                    cwd=str(profile_dir),
                    capture_output=True
                )

def open_firewall_port(port):
    """Abre un puerto en el firewall"""
    try:
        if shutil.which('ufw'):
            subprocess.run(['ufw', 'allow', f'{port}/tcp'], capture_output=True)
            print(f"Puerto {port}/tcp abierto en ufw")
        elif shutil.which('firewall-cmd'):
            subprocess.run(['firewall-cmd', '--permanent', f'--add-port={port}/tcp'], capture_output=True)
            subprocess.run(['firewall-cmd', '--reload'], capture_output=True)
            print(f"Puerto {port}/tcp abierto en firewalld")
    except Exception as e:
        print(color(f"No se pudo abrir el puerto: {e}", Colors.YELLOW))

def packwiz_start_server(profile_name):
    """Inicia el servidor HTTP para packwiz"""
    profile_dir = get_profile_dir(profile_name)
    pack_toml = profile_dir / "pack.toml"

    if not pack_toml.exists():
        print(color("Packwiz no inicializado. Configura primero.", Colors.RED))
        return False

    if _packwiz_http_running():
        print(color("El servidor HTTP ya esta corriendo.", Colors.YELLOW))
        return True

    # Abrir puerto
    open_firewall_port(PACKWIZ_PORT)

    # Iniciar servidor HTTP
    http_cmd = f"cd {profile_dir} && python3 -m http.server {PACKWIZ_PORT}"
    subprocess.run(['screen', '-dmS', PACKWIZ_SCREEN, 'bash', '-c', http_cmd])

    print(color(f"Servidor HTTP iniciado en puerto {PACKWIZ_PORT}", Colors.GREEN))
    packwiz_show_url(profile_name)
    return True

def packwiz_stop_server():
    """Detiene el servidor HTTP de packwiz"""
    if not _packwiz_http_running():
        print(color("El servidor HTTP no esta corriendo.", Colors.YELLOW))
        return

    subprocess.run(['screen', '-S', PACKWIZ_SCREEN, '-X', 'quit'], capture_output=True)
    print(color("Servidor HTTP detenido.", Colors.GREEN))

def packwiz_show_url(profile_name):
    """Muestra la URL para jugadores"""
    profile_dir = get_profile_dir(profile_name)
    pack_toml = profile_dir / "pack.toml"

    if not pack_toml.exists():
        print(color("Packwiz no configurado.", Colors.RED))
        return

    # Obtener IP publica
    try:
        with urllib.request.urlopen('https://api.ipify.org', timeout=5) as response:
            public_ip = response.read().decode('utf-8')
    except:
        public_ip = "<TU_IP>"

    print(f"\n{color('URL para jugadores:', Colors.BOLD)}")
    print(f"\n  http://{public_ip}:{PACKWIZ_PORT}/pack.toml")
    print(f"\n{color('Instrucciones:', Colors.CYAN)}")
    print("  1. Instala packwiz-installer-bootstrap en el launcher")
    print("  2. Configura la URL anterior como pack URL")
    print("  3. Los mods se sincronizaran automaticamente")

# ============ MENU PERFILES ============

def profiles_menu():
    """Submenu de perfiles"""
    while True:
        clear()
        print(f"\n{color('=== Perfiles ===', Colors.BOLD)}\n")

        print(f"  {color('[1]', Colors.BOLD)} Ver perfiles")
        print(f"  {color('[2]', Colors.BOLD)} Cambiar perfil")
        print(f"  {color('[3]', Colors.BOLD)} Crear perfil")
        print(f"  {color('[4]', Colors.BOLD)} Eliminar perfil")
        print(f"  {color('[5]', Colors.BOLD)} Mods")
        print(f"  {color('[0]', Colors.BOLD)} Volver")

        choice = input("\n  Opcion: ").strip()

        if choice == '1':
            show_profiles()
            input("\nEnter para continuar...")
        elif choice == '2':
            switch_profile()
            input("\nEnter para continuar...")
        elif choice == '3':
            create_profile()
            input("\nEnter para continuar...")
        elif choice == '4':
            delete_profile()
            input("\nEnter para continuar...")
        elif choice == '5':
            mods_menu()
        elif choice == '0':
            break

# ============ DESCARGAS ============

def get_available_versions(loader="fabric"):
    """Obtiene versiones de Minecraft disponibles"""
    try:
        if loader == "forge":
            url = "https://files.minecraftforge.net/net/minecraftforge/forge/promotions_slim.json"
            with urllib.request.urlopen(url, timeout=10) as response:
                data = json.loads(response.read())
            versions = set()
            for key in data.get('promos', {}):
                mc_ver = key.rsplit('-', 1)[0]
                versions.add(mc_ver)
            def ver_key(v):
                try:
                    return [int(x) for x in v.split('.')]
                except:
                    return [0]
            return sorted(versions, key=ver_key, reverse=True)[:20]
        else:
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

def get_forge_version(mc_version):
    """Obtiene la version de Forge recomendada para una version de MC"""
    try:
        url = "https://files.minecraftforge.net/net/minecraftforge/forge/promotions_slim.json"
        with urllib.request.urlopen(url, timeout=10) as response:
            data = json.loads(response.read())
        promos = data.get('promos', {})
        return promos.get(f"{mc_version}-recommended") or promos.get(f"{mc_version}-latest")
    except:
        return None

def download_forge(version, profile_dir):
    """Descarga e instala el servidor Forge para una version"""
    try:
        forge_ver = get_forge_version(version)
        if not forge_ver:
            print(color(f"No se encontro Forge para Minecraft {version}.", Colors.RED))
            return None

        full_ver = f"{version}-{forge_ver}"
        installer_name = f"forge-{full_ver}-installer.jar"
        installer_url = f"https://maven.minecraftforge.net/net/minecraftforge/forge/{full_ver}/{installer_name}"

        installer_path = profile_dir / installer_name

        print(f"Descargando Forge {full_ver}...")
        urllib.request.urlretrieve(installer_url, installer_path)

        print("Instalando servidor Forge (esto puede tardar)...")
        result = subprocess.run(
            ['java', '-jar', str(installer_path), '--installServer'],
            cwd=str(profile_dir),
            capture_output=True, text=True
        )

        if result.returncode != 0:
            print(color(f"Error instalando Forge: {result.stderr[:200]}", Colors.RED))
            return None

        # Limpiar installer
        installer_path.unlink(missing_ok=True)
        installer_log = profile_dir / (installer_name + ".log")
        if installer_log.exists():
            installer_log.unlink()

        print(color(f"Forge {full_ver} instalado.", Colors.GREEN))
        return "forge"

    except Exception as e:
        print(color(f"Error: {e}", Colors.RED))
        return None

def download_essential_mods(version, mods_dir, loader="fabric"):
    """Descarga mods esenciales"""
    if loader == "forge":
        mods = [
            ("l6YH9Als", "Spark"),        # Profiler/rendimiento
        ]
    else:
        mods = [
            ("gvQqBUqZ", "Lithium"),      # Optimizacion
            ("P7dR8mSH", "Fabric API"),   # API base
        ]

    for project_id, name in mods:
        try:
            print(f"Descargando {name}...")
            url = f"https://api.modrinth.com/v2/project/{project_id}/version?game_versions=%5B%22{version}%22%5D&loaders=%5B%22{loader}%22%5D"
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
        loader_name = profile_data.get('loader', 'fabric').capitalize() if profile_data else '?'
        status = color("ONLINE", Colors.GREEN) if running else color("OFFLINE", Colors.RED)
        print(f"  Perfil: {color(profile, Colors.CYAN)} (v{version} - {loader_name})  [{status}]")
    else:
        print(f"  {color('No hay perfil activo', Colors.YELLOW)}")

    print(f"""
  {color('[1]', Colors.BOLD)} {'Detener' if running else 'Iniciar'} servidor
  {color('[2]', Colors.BOLD)} Consola
  {color('[3]', Colors.BOLD)} Logs
  {color('[4]', Colors.BOLD)} Perfiles
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
            profiles_menu()
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
            mods_menu()
        elif cmd == 'import':
            # mc import <archivo.mrpack>
            if len(sys.argv) > 2:
                import_mrpack(mrpack_path_str=sys.argv[2])
            else:
                import_mrpack()
        elif cmd == 'pack':
            # mc pack [subcomando]
            profile_name = get_active_profile()
            if not profile_name:
                print(color("No hay perfil activo.", Colors.RED))
            elif len(sys.argv) > 2:
                subcmd = sys.argv[2].lower()
                if subcmd == 'refresh':
                    packwiz_refresh(profile_name)
                elif subcmd == 'url':
                    packwiz_show_url(profile_name)
                elif subcmd == 'init':
                    packwiz_init(profile_name)
                elif subcmd == 'start':
                    packwiz_start_server(profile_name)
                elif subcmd == 'stop':
                    packwiz_stop_server()
                else:
                    print(f"Subcomando desconocido: {subcmd}")
                    print("Subcomandos: refresh, url, init, start, stop")
            else:
                packwiz_menu(profile_name)
        elif cmd == 'help':
            print("""
Uso: mc [comando]

Comandos:
  start          Iniciar servidor
  stop           Detener servidor
  restart        Reiniciar servidor
  console        Abrir consola
  logs           Ver logs
  status         Ver estado
  profiles       Listar perfiles
  new            Crear perfil
  mods           Gestionar mods
  import <file>  Importar modpack .mrpack
  pack           Menu packwiz
  pack refresh   Refrescar manifiesto packwiz
  pack url       Mostrar URL para jugadores
  pack init      Inicializar packwiz
  pack start     Iniciar servidor HTTP
  pack stop      Detener servidor HTTP
  help           Mostrar ayuda

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
