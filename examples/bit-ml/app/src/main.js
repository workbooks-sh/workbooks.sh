import { mount } from 'svelte';
import './app.css';
import './vendor/orgitorial.css';   // story-body styling; --org-* vars remapped onto bit.ml tokens in app.css
import App from './App.svelte';

export default mount(App, { target: document.getElementById('app') });
