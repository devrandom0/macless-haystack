.PHONY: help up down clean logs test analyze build

help:
	@echo "Targets:"
	@echo "  up       - start the server via docker compose"
	@echo "  down     - stop the server (docker compose down)"
	@echo "  clean    - stop the server and remove its volumes (docker compose down -v)"
	@echo "  logs     - follow server logs"
	@echo "  test     - run Python and Flutter test suites"
	@echo "  analyze  - run flutter analyze"
	@echo "  build    - build the server image and the Android APK"
	@echo "             (APK build needs a local Flutter SDK, not the Docker wrapper,"
	@echo "             since Docker can't produce a signed/installable APK here)"

up:
	docker compose up -d

down:
	docker compose down

clean:
	docker compose down -v

logs:
	docker compose logs -f

test:
	cd endpoint && test -d venv || python3 -m venv venv
	cd endpoint && ./venv/bin/pip install -q -r requirements.txt -r requirements-dev.txt
	cd endpoint && ./venv/bin/pytest
	cd macless_haystack && ../scripts/flutter-docker.sh test

analyze:
	cd macless_haystack && ../scripts/flutter-docker.sh analyze

build:
	docker compose build
	cd macless_haystack && flutter build apk
