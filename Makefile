# Builds the bulb helper the widget runs from bin/.
bin/lucerna: helper/*.go helper/go.mod
	cd helper && go build -trimpath -ldflags="-s -w" -o ../bin/lucerna .

.PHONY: clean
clean:
	rm -rf bin
