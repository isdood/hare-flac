.POSIX:

HARE = hare
HARECFLAGS =

.PHONY: all flac-enc flac-dec test clean

all: flac-enc flac-dec

flac-enc:
	$(HARE) build $(HARECFLAGS) -R -o flac-enc cmd/flac-enc/

flac-dec:
	$(HARE) build $(HARECFLAGS) -R -o flac-dec cmd/flac-dec/

test:
	$(HARE) test vendor/wav/
	$(HARE) test vendor/lpc/

clean:
	rm -f flac-enc flac-dec
