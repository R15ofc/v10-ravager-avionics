return {
  config_version = 2,

  aircraft_id = "v10-ravager",
  protocol = "v10_avionics_v1",

  display = {
    monitor_scale = 0.5,
    link_timeout = 3.0,
    command_repeat = 2,
  },

  engine = {
    side = "front",
    analog = true,
    on_value = 15,
    off_value = 0,
    status_interval = 0.25,
  },

  telemetry = {
    gps_timeout = 0.05,
    speed_units = "m/s",
  },

  speaker = {
    side = "top",
    volume = 1.0,
    audio_enabled = true,
    audio_path = "/v10av/audio",
  },
}
