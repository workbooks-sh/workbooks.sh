import { mount } from 'svelte'
import Root from './Root.svelte'
import './app.css'

export default mount(Root, { target: document.getElementById('app') })
