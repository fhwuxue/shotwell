/* Copyright 2016 Software Freedom Conservancy Inc.
 *
 * This software is licensed under the GNU Lesser General Public License
 * (version 2.1 or later).  See the COPYING file in this distribution.
 */

public class DiscoveredCamera {
    public GPhoto.Camera gcamera;
    public string uri;
    public string display_name;
    public string? icon;

    private string port;
    private string camera_name;
    private string[] mount_uris;

    public DiscoveredCamera(string name, string port, GPhoto.PortInfo port_info, GPhoto.CameraAbilities camera_abilities) throws GPhotoError {
        this.port = port;
        this.camera_name = name;
        this.uri = "gphoto2://[%s]".printf(port);

        this.mount_uris = new string[0];
        this.mount_uris += this.uri;
        this.mount_uris += "mtp://[%s]".printf(port);

        var res = GPhoto.Camera.create(out this.gcamera);

        if (res != GPhoto.Result.OK) {
            throw new GPhotoError.LIBRARY("[%d] Unable to create camera object for %s: %s",
                (int) res, name, res.as_string());
        }

        res = gcamera.set_abilities(camera_abilities);
        if (res != GPhoto.Result.OK) {
            throw new GPhotoError.LIBRARY("[%d] Unable to set camera abilities for %s: %s",
                (int) res, name, res.as_string());
        }

        res = gcamera.set_port_info(port_info);
        if (res != GPhoto.Result.OK) {
            throw new GPhotoError.LIBRARY("[%d] Unable to set port infor for %s: %s",
                (int) res, name, res.as_string());
        }

        var path = CameraTable.get_port_path(port);
        if (path != null) {
            var monitor = VolumeMonitor.get();
            foreach (var volume in monitor.get_volumes()) {
                if (volume.get_identifier(VolumeIdentifier.UNIX_DEVICE) == path) {
                    this.display_name = volume.get_name();
                    this.icon = volume.get_symbolic_icon().to_string();
                }
            }

#if HAVE_UDEV
            var client = new GUdev.Client(null);
            var device = client.query_by_device_file(path);


            // Create alternative uris (used for unmount)
            var serial = device.get_property("ID_SERIAL");
            this.mount_uris += "gphoto2://%s".printf(serial);
            this.mount_uris += "mtp://%s".printf(serial);

            // Look-up alternative display names
            if (display_name == null) {
                display_name = device.get_sysfs_attr("product");
            }

            if (display_name == null) {
                display_name = device.get_property("ID_MODEL");
            }
#endif
        }

        if (port.has_prefix("disk:")) {
            try {
                var mount = File.new_for_path (port.substring(5)).find_enclosing_mount();
                var volume = mount.get_volume();
                if (volume != null) {
                    // Translators: First %s is the name of camera as gotten from GPhoto, second is the GVolume name, e.g. Mass storage camera (510MB volume)
                    display_name = _("%s (%s)").printf (name, volume.get_name ());
                    icon = volume.get_symbolic_icon().to_string();
                } else {
                    // Translators: First %s is the name of camera as gotten from GPhoto, second is the GMount name, e.g. Mass storage camera (510MB volume)
                    display_name = _("%s (%s)").printf (name, mount.get_name ());
                    icon = mount.get_symbolic_icon().to_string();
                }

            } catch (Error e) { }
        }

        if (display_name == null) {
            this.display_name = camera_name;
        }
    }

    public Mount? get_mount() {
        foreach (var uri in this.mount_uris) {
            var f = File.new_for_uri(uri);
            try {
                var mount = f.find_enclosing_mount(null);
                if (mount != null)
                    return mount;
            } catch (Error error) {}
        }

        return null;
    }
}

public class CameraTable {
    private const int UPDATE_DELAY_MSEC = 1000;
    
    // list of subsystems being monitored for events
    private const string[] SUBSYSTEMS = { "usb", "block", null };
    
    private static CameraTable instance = null;
    
#if HAVE_UDEV
    private GUdev.Client client = new GUdev.Client(SUBSYSTEMS);
#endif
    private OneShotScheduler camera_update_scheduler = null;
    private GPhoto.Context null_context = new GPhoto.Context();
    private GPhoto.CameraAbilitiesList abilities_list;
    private VolumeMonitor volume_monitor;
    
    private Gee.HashMap<string, DiscoveredCamera> camera_map = new Gee.HashMap<string, DiscoveredCamera>();

    public signal void camera_added(DiscoveredCamera camera);
    
    public signal void camera_removed(DiscoveredCamera camera);
    
    private CameraTable() {
        camera_update_scheduler = new OneShotScheduler("CameraTable update scheduler",
            on_update_cameras);
        
        // listen for interesting events on the specified subsystems

#if HAVE_UDEV
        client.uevent.connect(on_udev_event);
#else
        Timeout.add_seconds(10, () => { camera_update_scheduler.after_timeout(UPDATE_DELAY_MSEC, true); return true; });
#endif
        volume_monitor = VolumeMonitor.get();
        volume_monitor.volume_changed.connect(on_volume_changed);
        volume_monitor.volume_added.connect(on_volume_changed);
        
        // because loading the camera abilities list takes a bit of time and slows down app
        // startup, delay loading it (and notifying any observers) for a small period of time,
        // after the dust has settled
        Timeout.add(500, delayed_init);
    }
    
    private bool delayed_init() {
        // We disable this here so cameras that are already connected at the time
        // the application is launched don't interfere with normal navigation...
        ((LibraryWindow) AppWindow.get_instance()).set_page_switching_enabled(false);
        
        try {
            init_camera_table();
        } catch (GPhotoError err) {
            warning("Unable to initialize camera table: %s", err.message);
            
            return false;
        }
        
        try {
            update_camera_table();
        } catch (GPhotoError err) {
            warning("Unable to update camera table: %s", err.message);
        }
        
        // ...and re-enable it here, so that cameras connected -after- the initial
        // populating of the table will trigger a switch to the import page, as before.
        ((LibraryWindow) AppWindow.get_instance()).set_page_switching_enabled(true);
        return false;
    }
    
    public static CameraTable get_instance() {
        if (instance == null)
            instance = new CameraTable();
        
        return instance;
    }
    
    public Gee.Iterable<DiscoveredCamera> get_cameras() {
        return camera_map.values;
    }
    
    public int get_count() {
        return camera_map.size;
    }
    
    public DiscoveredCamera? get_for_uri(string uri) {
        return camera_map.get(uri);
    }

    private void do_op(GPhoto.Result res, string op) throws GPhotoError {
        if (res != GPhoto.Result.OK)
            throw new GPhotoError.LIBRARY("[%d] Unable to %s: %s", (int) res, op, res.as_string());
    }
    
    private void init_camera_table() throws GPhotoError {
        do_op(GPhoto.CameraAbilitiesList.create(out abilities_list), "create camera abilities list");
        do_op(abilities_list.load(null_context), "load camera abilities list");
    }
    
    public static string get_port_uri(string port) {
        return "gphoto2://[%s]/".printf(port);
    }
    
    public static string? get_port_path(string port) {
        // Accepted format is usb:001,005
        return port.has_prefix("usb:") ? 
            "/dev/bus/usb/%s".printf(port.substring(4).replace(",", "/")) : null;
    }
    
    private void update_camera_table() throws GPhotoError {
        // need to do this because virtual ports come and go in the USB world (and probably others)
        GPhoto.PortInfoList port_info_list;
        do_op(GPhoto.PortInfoList.create(out port_info_list), "create port list");
        do_op(port_info_list.load(), "load port list");

        GPhoto.CameraList camera_list;
        do_op(GPhoto.CameraList.create(out camera_list), "create camera list");
        do_op(abilities_list.detect(port_info_list, camera_list, null_context), "detect cameras");
        
        Gee.HashMap<string, string> detected_map = new Gee.HashMap<string, string>();

        // go through the detected camera list and glean their ports
        for (int ctr = 0; ctr < camera_list.count(); ctr++) {
            string name;
            do_op(camera_list.get_name(ctr, out name), "get detected camera name");

            string port;
            do_op(camera_list.get_value(ctr, out port), "get detected camera port");
            
            debug("Detected %d/%d %s @ %s", ctr + 1, camera_list.count(), name, port);
            
            detected_map.set(port, name);
        }
        
        // find cameras that have disappeared
        DiscoveredCamera[] missing = new DiscoveredCamera[0];
        foreach (DiscoveredCamera camera in camera_map.values) {
            GPhoto.PortInfo port_info;
            string tmp_path;
            
            do_op(camera.gcamera.get_port_info(out port_info), 
                "retrieve missing camera port information");
            
            port_info.get_path(out tmp_path);
            
            GPhoto.CameraAbilities abilities;
            do_op(camera.gcamera.get_abilities(out abilities), "retrieve camera abilities");
            
            if (detected_map.has_key(tmp_path)) {
                debug("Found camera for %s @ %s in detected map", abilities.model, tmp_path);
                
                continue;
            }
            
            debug("%s @ %s missing", abilities.model, tmp_path);
            
            missing += camera;
        }
        
        // have to remove from hash map outside of iterator
        foreach (DiscoveredCamera camera in missing) {
            GPhoto.PortInfo port_info;
            string tmp_path;
            
            do_op(camera.gcamera.get_port_info(out port_info),
                "retrieve missing camera port information");
            port_info.get_path(out tmp_path);
            
            GPhoto.CameraAbilities abilities;
            do_op(camera.gcamera.get_abilities(out abilities), "retrieve missing camera abilities");

            debug("Removing from camera table: %s @ %s", abilities.model, tmp_path);

            camera_map.unset(get_port_uri(tmp_path));
            
            camera_removed(camera);
        }

        // add cameras which were not present before
        foreach (string port in detected_map.keys) {
            string name = detected_map.get(port);
            string uri = get_port_uri(port);

            if (camera_map.has_key(uri)) {
                // already known about
                debug("%s @ %s already registered, skipping", name, port);
                
                continue;
            }

            int index = port_info_list.lookup_path(port);
            if (index < 0)
                do_op((GPhoto.Result) index, "lookup port %s".printf(port));
            
            GPhoto.PortInfo port_info;
            string tmp_path;
            
            do_op(port_info_list.get_info(index, out port_info), "get port info for %s".printf(port));
            port_info.get_path(out tmp_path);
            
            // this should match, every time
            assert(port == tmp_path);
            
            index = abilities_list.lookup_model(name);
            if (index < 0)
                do_op((GPhoto.Result) index, "lookup camera model %s".printf(name));

            GPhoto.CameraAbilities camera_abilities;
            do_op(abilities_list.get_abilities(index, out camera_abilities), 
                "lookup camera abilities for %s".printf(name));
                
            debug("Adding to camera table: %s @ %s", name, port);
            
            var camera = new DiscoveredCamera(name, port, port_info, camera_abilities);
            camera_map.set(uri, camera);
            
            camera_added(camera);
        }
    }
    
#if HAVE_UDEV
    private void on_udev_event(string action, GUdev.Device device) {
        debug("udev event: %s on %s", action, device.get_name());
        
        // Device add/removes often arrive in pairs; this allows for a single
        // update to occur when they come in all at once
        camera_update_scheduler.after_timeout(UPDATE_DELAY_MSEC, true);
    }
#endif
    
    public void on_volume_changed(Volume volume) {
        camera_update_scheduler.after_timeout(UPDATE_DELAY_MSEC, true);
    }
    
    private void on_update_cameras() {
        try {
            get_instance().update_camera_table();
        } catch (GPhotoError err) {
            warning("Error updating camera table: %s", err.message);
        }
    }
}

