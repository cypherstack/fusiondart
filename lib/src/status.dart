enum FusionStatus {
  setup("setup"),
  connecting("connecting"),
  running("running"),
  complete("complete"),
  failed("failed"),
  exception("Exception");

  const FusionStatus(this.value);

  final String value;
}
