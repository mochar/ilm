package org.libsdl.ilm;

import org.libsdl.app.SDLActivity;

public class IlmActivity extends SDLActivity {
    protected String[] getLibraries() {
        return new String[] { "SDL3", "ilm_gui" };
    }
}
