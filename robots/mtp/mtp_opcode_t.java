/*
 * Automatically generated by jrpcgen 1.0.5 on 14-Feb-05 4:35:56 PM
 * jrpcgen is part of the "Remote Tea" ONC/RPC package for Java
 * See http://acplt.org/ks/remotetea.html for details
 */
package net.emulab;
import org.acplt.oncrpc.*;
import java.io.IOException;

/**
 * Enumeration (collection of constants).
 */
public interface mtp_opcode_t {

    public static final int MTP_CONTROL_ERROR = 11;
    public static final int MTP_CONTROL_NOTIFY = 12;
    public static final int MTP_CONTROL_INIT = 13;
    public static final int MTP_CONTROL_CLOSE = 14;
    public static final int MTP_CONFIG_VMC = 20;
    public static final int MTP_CONFIG_RMC = 21;
    public static final int MTP_REQUEST_POSITION = 30;
    public static final int MTP_REQUEST_ID = 31;
    public static final int MTP_UPDATE_POSITION = 40;
    public static final int MTP_UPDATE_ID = 41;
    public static final int MTP_COMMAND_GOTO = 50;
    public static final int MTP_COMMAND_STOP = 51;
    public static final int MTP_TELEMETRY = 60;
    public static final int MTP_WIGGLE_REQUEST = 70;
    public static final int MTP_WIGGLE_STATUS = 71;
    public static final int MTP_REQUEST_REPORT = 80;
    public static final int MTP_CONTACT_REPORT = 81;
    public static final int MTP_OPCODE_MAX = 81+1;

}
// End of mtp_opcode_t.java
