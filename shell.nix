{ pkgs ? import <nixpkgs> {} }:

let
  # Determine platform for the config file dynamically
  platform = if pkgs.stdenv.isLinux then "linux"
             else if pkgs.stdenv.isFreeBSD then "freebsd"
             else "linux";

  # Compiler Frontend - Version 0.26.0
  harec = pkgs.stdenv.mkDerivation {
    pname = "harec";
    version = "0.26.0";

    src = pkgs.fetchgit {
      url = "https://git.sr.ht/~sircmpwn/harec";
      rev = "1e65ac55d1e9e944664e33fc03c642460ab1746d";
      sha256 = "1bzmd4j2q6kdgz8zxs6qwy57fzh7wh7xwps9rcmcrhwl5zngff3b";
    };

    nativeBuildInputs = [ pkgs.qbe pkgs.scdoc ];
    buildInputs = [ pkgs.qbe ];

    configurePhase = ''
      cp configs/${platform}.mk config.mk
      sed -i "s|PREFIX = /usr/local|PREFIX = $out|" config.mk
    '';
  };

  # Main Toolchain & Stdlib - Version 0.26.0.1
  hare = pkgs.stdenv.mkDerivation {
    pname = "hare";
    version = "0.26.0.1";

    src = pkgs.fetchgit {
      url = "https://git.sr.ht/~sircmpwn/hare";
      rev = "1593e40549de2e1e194ec52021b2b4744089db41";
      sha256 = "0gjz9aw53g8p8cb9555jg3wbzhhh6dazhx59vfh331dnfccvg6ya";
    };

    nativeBuildInputs = [ harec pkgs.qbe pkgs.scdoc pkgs.makeWrapper ];

    configurePhase = ''
      # Redirect cache to a writable directory in the Nix sandbox
      export HARECACHE=$NIX_BUILD_TOP/.cache

      cp configs/${platform}.mk config.mk
      sed -i "s|PREFIX = /usr/local|PREFIX = $out|" config.mk
      sed -i "s|HAREC = harec|HAREC = ${harec}/bin/harec|" config.mk
    '';

    # Ensures 'hare' knows where 'qbe' and 'harec' are located
    postInstall = ''
      wrapProgram $out/bin/hare \
        --prefix PATH : ${pkgs.lib.makeBinPath [ pkgs.qbe harec ]}
    '';
  };

in
pkgs.mkShell {
  packages = [
    hare
    pkgs.qbe
  ];

  shellHook = ''
    echo "--- Hare Development Environment ---"
    echo "hare:  ${hare.version}"
    echo "harec: ${harec.version}"
    echo ""
    export HAREPATH="${hare}/src/hare/stdlib:$(pwd)/vendor:$(pwd)/src"
  '';
}
