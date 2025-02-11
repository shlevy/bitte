{ buildGoModule, fetchgit, lib }:

buildGoModule rec {
  pname = "cue";
  version = "0.4.0";

  src = fetchgit {
    url = "https://cue.googlesource.com/cue";
    rev = "v0.4.0";
    sha256 = "sha256-rcGEl+CMFyxZKsOKhVimhv5/ONo3xS6FjgKModZGR2o=";
  };

  vendorSha256 = "sha256-eSKVlBgnHR1R0j1lNwtFoIgRuj8GqoMbvuBl/N1SanY=";

  doCheck = false;

  subPackages = [ "cmd/cue" ];

  buildFlagsArray =
    [ "-ldflags=-X cuelang.org/go/cmd/cue/cmd.version=${version}" ];

  meta = {
    description =
      "A data constraint language which aims to simplify tasks involving defining and using data";
    homepage = "https://cuelang.org/";
    maintainers = with lib.maintainers; [ solson ];
    license = lib.licenses.asl20;
  };
}
