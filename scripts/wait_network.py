import time
from http.client import HTTPException
from urllib.request import Request, urlopen


def main():
    url = "https://data.seattle.gov/api/views/tazs-3rd5.json"
    deadline = time.monotonic() + 15 * 60

    while True:
        try:
            req = Request(url, headers={"User-Agent": "CivicaBatch/1.0"})
            with urlopen(req, timeout=30) as response:
                response.read(1)
            print("Conexión con el origen disponible.", flush=True)
            return
        except (OSError, HTTPException) as error:
            if time.monotonic() >= deadline:
                raise RuntimeError("El origen no está disponible.") from error
            print(f"Esperando conexión con el origen: {error}", flush=True)
            time.sleep(30)


if __name__ == "__main__":
    main()
