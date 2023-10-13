enum FusionStatus {
  setup("setup"),
  waiting("waiting"),
  connecting("connecting"),
  running("running"),
  complete("complete"),
  failed("failed"),
  exception("Exception"),
  reset("reset"); // Used to reset the state of the Fusion UI.

  const FusionStatus(this.value);

  final String value;
}
