from pathlib import Path
import subprocess


# Yo kennard all codes go here para organized lets do some functions stuff para organized

def main(): 
    retrieve_data()

def retrieve_data():
    base_dir = Path(__file__).resolve().parent
    path_to_file = base_dir / "pagasa_parser" / "output" / "bulletin.pdf"
    bat_path = base_dir / "pagasa_parser" / "poll.bat"

    if path_to_file.is_file():
        print("DATA ALREADY EXISTS")
    else:
        try:
            result = subprocess.run([bat_path], shell=True, check=True)
            print("DATA POLLED")
        except Exception as e:
            print("COULD NOT POLL")

main()